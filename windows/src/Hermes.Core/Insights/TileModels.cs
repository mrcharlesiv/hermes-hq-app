using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Net;
using Hermes.Core.Settings;

namespace Hermes.Core.Insights;

// [tile-models] Which model updates the tiles (HermesKit/Pages/TileModels.swift & App/Pages/Artifacts/TileModelSync.swift):
// Settings › Tile Model sets, per gateway account, a Default model (null: each bot's own) and a Fallback model
// (null: each bot's own). A tile's Updates › Model sets an override for that tile's job. `TileModels.Desired` turns
// those into the one change the job needs, or null; the app remembers each pin it applied (`TileModelSettings.Applied`),
// so it only ever takes back its own pins, never one set by hand, by the bot, or on the Jobs page.

/// A provider and model, as the settings keep them and `fallback_providers` lists them.
public sealed record TileModelPick
{
    public string Provider { get; }
    public string Model { get; }

    public TileModelPick(string provider, string model)
    {
        Provider = (provider ?? "").Trim();
        Model = (model ?? "").Trim();
    }

    /// The same model: a missing provider on either side matches any (a hand pin may name the model alone).
    public bool Same(TileModelPick other)
    {
        if (Model != other.Model) return false;
        return Provider.Length == 0 || other.Provider.Length == 0
            || string.Equals(Provider, other.Provider, StringComparison.OrdinalIgnoreCase);
    }

    public JsonObject ToJson() => new() { ["provider"] = Provider, ["model"] = Model };

    public static TileModelPick? FromJson(JsonNode? node)
    {
        if (node is not JsonObject) return null;
        var model = node.Str("model")?.Trim();
        if (string.IsNullOrEmpty(model)) return null;
        return new TileModelPick(node.Str("provider") ?? "", model);
    }

    /// `fallback_providers` as a job carries it: `[{provider, model}]` (a bare `"provider:model"` string read too).
    public static List<TileModelPick>? ParseList(JsonNode? value)
    {
        if (value is not JsonArray rows) return null;
        var list = new List<TileModelPick>();
        foreach (var item in rows)
        {
            if (J.AsString(item) is { } text)
            {
                var idx = text.IndexOf(':');
                list.Add(idx >= 0 ? new TileModelPick(text[..idx], text[(idx + 1)..]) : new TileModelPick("", text));
                continue;
            }
            if (FromJson(item) is { } pick) list.Add(pick);
        }
        return list;
    }
}

/// What the app last wrote to a job: its pin, and the fallback it sent with it (null: none sent).
public sealed record TileModelApplied(TileModelPick Pin, TileModelPick? Fallback)
{
    public JsonObject ToJson()
    {
        var o = new JsonObject { ["provider"] = Pin.Provider, ["model"] = Pin.Model };
        if (Fallback != null) o["fallback"] = Fallback.ToJson();
        return o;
    }

    public static TileModelApplied? FromJson(JsonNode? node)
    {
        if (TileModelPick.FromJson(node) is not { } pin) return null;
        return new TileModelApplied(pin, TileModelPick.FromJson(node?.Get("fallback")));
    }
}

public static class TileModels
{
    public enum FallbackAction { Leave, Set, Clear }

    /// The one write a job needs to run the model the settings ask for.
    public sealed record Plan(
        TileModelPick? Pin,
        FallbackAction Fallback,
        TileModelPick? FallbackPick,
        TileModelApplied? Record)
    {
        /// The `updates` payload of `PUT /api/cron/jobs/<id>`.
        public JsonObject Updates()
        {
            var o = new JsonObject();
            if (Pin != null)
            {
                o["model"] = Pin.Model;
                o["provider"] = Pin.Provider.Length == 0 ? null : Pin.Provider;
            }
            else
            {
                o["model"] = null;
                o["provider"] = null;
            }
            switch (Fallback)
            {
                case FallbackAction.Leave: break;
                case FallbackAction.Set when FallbackPick != null:
                    o["fallback_providers"] = new JsonArray(FallbackPick.ToJson());
                    break;
                case FallbackAction.Clear:
                    o["fallback_providers"] = null;
                    break;
            }
            return o;
        }
    }

    /// A job that runs a script and no model (`no_agent`, or a script and no prompt): never touched.
    public static bool IsScriptOnly(TileCronJob job) => TileJobs.IsScriptOnly(job);

    /// The job's own pin, null when it follows its bot.
    public static TileModelPick? PinOf(TileCronJob job)
    {
        var model = job.Model?.Trim();
        return string.IsNullOrEmpty(model) ? null : new TileModelPick(job.Provider ?? "", model);
    }

    /// The pin on the job is one the app put there (and nobody changed since).
    public static bool IsAppPin(TileCronJob job, TileModelApplied? applied) =>
        PinOf(job) is { } pin && applied != null && pin.Same(applied.Pin);

    /// The change `job` needs, or null when it needs none (or isn't the app's to change).
    public static Plan? Desired(
        TileCronJob job,
        TileModelPick? overridePick,
        TileModelPick? defaultPick,
        TileModelPick? fallbackPick,
        TileModelApplied? applied,
        IReadOnlyList<TileModelPick>? carriedFallbacks = null)
    {
        if (IsScriptOnly(job)) return null;
        var current = PinOf(job);
        var appPin = IsAppPin(job, applied);
        // A pin set somewhere else (by hand, by the bot, on the Jobs page, or changed there since the app's) is kept,
        // unless this tile has its own model: then the owner chose for this tile.
        if (overridePick == null && current != null && !appPin) return null;
        var target = overridePick ?? defaultPick;
        if (target == null)
        {
            // Each bot's own: only the app's own pin is taken back.
            if (current == null || !appPin) return null;
            var clear = applied?.Fallback != null && SentFallbackStands(carriedFallbacks, applied);
            return new Plan(null, clear ? FallbackAction.Clear : FallbackAction.Leave, null, null);
        }
        var pinMatches = current != null && current.Same(target);
        if (fallbackPick != null)
        {
            if (pinMatches && FallbackMatches(carriedFallbacks, fallbackPick, appPin ? applied : null)) return null;
            return new Plan(target, FallbackAction.Set, fallbackPick, new TileModelApplied(target, fallbackPick));
        }
        // Each bot's own fallback: no field, but the one the app sent earlier goes.
        if (appPin && applied?.Fallback != null && SentFallbackStands(carriedFallbacks, applied))
            return new Plan(target, FallbackAction.Clear, null, new TileModelApplied(target, null));
        return pinMatches ? null : new Plan(target, FallbackAction.Leave, null, new TileModelApplied(target, null));
    }

    private static bool FallbackMatches(IReadOnlyList<TileModelPick>? carried, TileModelPick fallback, TileModelApplied? applied)
    {
        if (carried != null) return carried.Count == 1 && carried[0].Same(fallback);
        return applied?.Fallback != null && applied.Fallback.Same(fallback);
    }

    private static bool SentFallbackStands(IReadOnlyList<TileModelPick>? carried, TileModelApplied? applied)
    {
        if (applied?.Fallback is not { } sent) return false;
        if (carried == null) return true;
        return carried.Any(c => c.Same(sent));
    }

    // ------------------------------------------------------------------ words

    public static string Name(TileModelPick pick) => ModelNames.DisplayModelName(pick.Model);

    public static string? RunningName(TileCronJob job, string? botModel)
    {
        if (IsScriptOnly(job)) return null;
        if (PinOf(job) is { } pin) return Name(pin);
        return string.IsNullOrWhiteSpace(botModel) ? null : botModel.Trim();
    }

    public static string UpdatesSubtitle(TileCronJob job, string? botModel, DateTimeOffset? now = null)
    {
        var status = TileJobs.Status(job, now ?? DateTimeOffset.Now);
        return RunningName(job, botModel) is { } name ? $"{status} · {name}" : status;
    }

    public static string ModelSubtitle(TileCronJob job, string botName, string? botModel)
    {
        if (IsScriptOnly(job)) return "A script, no model";
        if (PinOf(job) is { } pin) return Name(pin);
        if (!string.IsNullOrWhiteSpace(botModel)) return $"{botModel} · {botName}’s model";
        return $"{botName}’s own model";
    }

    public static string UseDefaultTitle(TileModelPick? defaultPick, string botName, string? botModel)
    {
        if (defaultPick != null) return $"Use Tile Default ({Name(defaultPick)})";
        if (!string.IsNullOrWhiteSpace(botModel)) return $"Use Tile Default ({botModel})";
        return $"Use Tile Default ({botName}’s Model)";
    }

    /// The short list under Use Tile Default: starred models, then recent ones, then (when those are none) the catalog's
    /// first few; the tile's own pick always listed. At most `limit`, each once.
    public static List<TileModelPick> ShortList(
        IEnumerable<string> favorites,
        IEnumerable<TileModelPick> recents,
        IEnumerable<TileModelPick> catalog,
        TileModelPick? keep,
        int limit = 6)
    {
        var list = new List<TileModelPick>();
        void Add(TileModelPick pick)
        {
            if (pick.Model.Length == 0) return;
            if (list.Any(x => x.Model == pick.Model && string.Equals(x.Provider, pick.Provider, StringComparison.OrdinalIgnoreCase))) return;
            list.Add(pick);
        }
        if (keep != null) Add(keep);
        foreach (var key in favorites)
        {
            var idx = key.IndexOf("::", StringComparison.Ordinal);
            if (idx < 0) continue;
            Add(new TileModelPick(key[..idx], key[(idx + 2)..]));
        }
        foreach (var pick in recents) Add(pick);
        if (list.Count <= (keep == null ? 0 : 1))
            foreach (var pick in catalog) Add(pick);
        return list.Take(Math.Max(0, limit)).ToList();
    }

    public const string EachBotsModel = "Each Bot’s Own Model";
    public const string EachBotsFallback = "Each Bot’s Own Fallback";
    public const string DefaultFooter = "Separate from your bots’ chat model. A cheaper, faster model usually handles tile updates well.";

    public static string DefaultValue(TileModelPick? chosen) => chosen != null ? Name(chosen) : EachBotsModel;
    public static string FallbackValue(TileModelPick? chosen) => chosen != null ? Name(chosen) : EachBotsFallback;

    public static string AppliedWords(int changed, IReadOnlyList<string> failed)
    {
        if (failed.Count > 0)
        {
            var count = failed.Count == 1 ? "1 tile" : $"{failed.Count} tiles";
            var done = changed == 0 ? "" : $" {(changed == 1 ? "1 other tile was" : $"{changed} other tiles were")} changed.";
            return $"Couldn’t change {count}: {failed[0]}{done}";
        }
        return changed switch
        {
            0 => "No tile’s job needed a change.",
            1 => "1 tile’s job changed.",
            _ => $"{changed} tiles’ jobs changed.",
        };
    }

    public static string Footer(TileModelPick? chosen, TileModelPick? fallback)
    {
        var lines = new List<string>
        {
            chosen == null
                ? "Each tile’s job runs its bot’s own model and falls back as that bot does. A tile’s own model (right-click the tile › Updates › Model) still wins."
                : "Tiles run this model unless a tile has its own (right-click the tile › Updates › Model). A model set on a job by hand or by its bot is kept.",
        };
        if (fallback != null && chosen == null)
            lines.Add("This fallback goes only with a picked model: a tile given its own model falls back to it. Tiles on their bot’s own model use that bot’s fallbacks.");
        if (fallback != null)
            lines.Add("The fallback goes with a picked model. Until your gateway’s Hermes can carry a fallback for each job, a tile on a picked model won’t fall back: if its model fails, the update fails.");
        else if (chosen != null)
            lines.Add("A tile on a picked model doesn’t use its bot’s fallbacks: if its model fails, the update fails. Pick a fallback to add one.");
        return string.Join("\n\n", lines);
    }
}

/// Per-account Default Model, Fallback Model, per-tile overrides and applied records under `hq.tileModels.*`
/// (`HermesKit/Pages/TileModels.swift` `TileModelSettings`).
public sealed class TileModelSettings(string accountId, IKeyValueStore store)
{
    public const string Prefix = "hq.tileModels.";

    public string AccountId { get; } = accountId;

    public static string Key(string name, string accountId) => $"{Prefix}{name}|{accountId}";
    private string KeyOf(string name) => Key(name, AccountId);

    private JsonNode? Read(string name) => store.Get(KeyOf(name)) is { Length: > 0 } raw ? J.Parse(raw) : null;
    private void Write(string name, JsonNode? node) => store.Set(KeyOf(name), node?.ToJsonString());

    public TileModelPick? DefaultModel
    {
        get => TileModelPick.FromJson(Read("default"));
        set => Write("default", value?.ToJson());
    }

    public TileModelPick? FallbackModel
    {
        get => TileModelPick.FromJson(Read("fallback"));
        set => Write("fallback", value?.ToJson());
    }

    public TileModelPick? Override(string jobKey) =>
        Read("overrides") is JsonObject all ? TileModelPick.FromJson(all[jobKey]) : null;

    public void SetOverride(TileModelPick? pick, string jobKey)
    {
        var all = Read("overrides") as JsonObject ?? new JsonObject();
        if (pick == null) all.Remove(jobKey);
        else all[jobKey] = pick.ToJson();
        Write("overrides", all.Count == 0 ? null : all);
    }

    public TileModelApplied? Applied(string jobKey) =>
        Read("applied") is JsonObject all ? TileModelApplied.FromJson(all[jobKey]) : null;

    public void SetApplied(TileModelApplied? record, string jobKey)
    {
        var all = Read("applied") as JsonObject ?? new JsonObject();
        if (record == null) all.Remove(jobKey);
        else all[jobKey] = record.ToJson();
        Write("applied", all.Count == 0 ? null : all);
    }

    public TileModels.Plan? Plan(TileCronJob job, IReadOnlyList<TileModelPick>? carriedFallbacks = null) =>
        TileModels.Desired(job, Override(job.Key), DefaultModel, FallbackModel, Applied(job.Key), carriedFallbacks);

    public void Wrote(TileModels.Plan plan, string jobKey) => SetApplied(plan.Record, jobKey);
}

/// [tile-models] Puts Settings › Tile Model and each tile's own model onto the tiles' jobs via
/// `PUT /api/cron/jobs/<id>` (`App/Pages/Artifacts/TileModelSync.swift`).
public sealed class TileModelSync
{
    public enum OutcomeKind { Unchanged, Changed, Failed }
    public readonly record struct Outcome(OutcomeKind Kind, string? Reason = null)
    {
        public static readonly Outcome Unchanged = new(OutcomeKind.Unchanged);
        public static readonly Outcome Changed = new(OutcomeKind.Changed);
        public static Outcome Failed(string reason) => new(OutcomeKind.Failed, reason);
    }

    public enum WriteKind { Done, Refused, Failed }
    public readonly record struct WriteResult(WriteKind Kind, string? Reason = null)
    {
        public static readonly WriteResult Done = new(WriteKind.Done);
        public static readonly WriteResult Refused = new(WriteKind.Refused, TileWords.ReadOnly);
        public static WriteResult Failed(string reason) => new(WriteKind.Failed, reason);
    }

    public static TileModelSync Shared { get; } = new();

    private readonly HashSet<string> _inFlight = new(StringComparer.Ordinal);
    private readonly Dictionary<string, TileModels.Plan> _tried = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (string? Name, DateTimeOffset At)> _botModels = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (List<TileModelPick> Picks, DateTimeOffset At)> _catalogs = new(StringComparer.Ordinal);
    private readonly object _lock = new();

    /// Raised when Tile Model settings or a tile's override changed for an account id.
    public event Action<string>? Changed;
    public void NotifyChanged(string accountId) => Changed?.Invoke(accountId);

    /// Writes `job`'s desired model/provider/fallback_providers when it needs a change.
    public async Task<Outcome> ReconcileAsync(
        TileCronJob job,
        string accountId,
        IKeyValueStore store,
        Func<TileCronJob, JsonObject, CancellationToken, Task<WriteResult>> writeJob,
        bool readOnlyGateway = false,
        bool force = false,
        IReadOnlyList<TileModelPick>? carriedFallbacks = null,
        CancellationToken ct = default)
    {
        var settings = new TileModelSettings(accountId, store);
        var key = accountId + "|" + job.Key;
        var plan = settings.Plan(job, carriedFallbacks);
        if (plan == null)
        {
            lock (_lock) _tried.Remove(key);
            return Outcome.Unchanged;
        }
        if (readOnlyGateway) return Outcome.Unchanged;
        lock (_lock)
        {
            if (_inFlight.Contains(key)) return Outcome.Unchanged;
            if (!force && _tried.TryGetValue(key, out var prior) && prior == plan) return Outcome.Unchanged;
            _inFlight.Add(key);
            _tried[key] = plan;
        }
        try
        {
            var result = await writeJob(job, plan.Updates(), ct).ConfigureAwait(false);
            switch (result.Kind)
            {
                case WriteKind.Done:
                    settings.Wrote(plan, job.Key);
                    return Outcome.Changed;
                case WriteKind.Refused:
                    return Outcome.Failed(result.Reason ?? TileWords.ReadOnly);
                default:
                    return Outcome.Failed(result.Reason ?? "Couldn’t update the job’s model.");
            }
        }
        catch (Exception e) when (e is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            return Outcome.Failed(e.Message);
        }
        finally
        {
            lock (_lock) _inFlight.Remove(key);
        }
    }

    public Task<Outcome> ReconcileAsync(
        TileCronJob job,
        string accountId,
        IKeyValueStore store,
        TileUpdates updates,
        bool readOnlyGateway = false,
        bool force = false,
        CancellationToken ct = default) =>
        ReconcileAsync(job, accountId, store, async (j, body, token) =>
        {
            try
            {
                await updates.UpdateJobAsync(j, body, token).ConfigureAwait(false);
                return WriteResult.Done;
            }
            catch (GatewayException e)
            {
                return e.Status == 403 ? WriteResult.Refused : WriteResult.Failed(e.Message);
            }
        }, readOnlyGateway, force, null, ct);

    /// Reconciles every page tile's job on `accountId`, prefetching bot job lists concurrently first.
    public async Task<(int Changed, List<string> Failed)> ReconcileAllAsync(
        IEnumerable<TilePin> pins,
        string accountId,
        IKeyValueStore store,
        TileUpdates updates,
        bool readOnlyGateway = false,
        CancellationToken ct = default)
    {
        var pages = pins.Where(p => p.IsPage).ToList();
        if (pages.Count == 0) return (0, []);
        await updates.PrefetchAsync(pages.Select(p => p.Profile), ct: ct).ConfigureAwait(false);
        return await ReconcileAllAsync(
            pages,
            accountId,
            store,
            async (pin, token) => (await updates.LookupAsync(pin, TileUpdates.Fresh, token).ConfigureAwait(false)).Job,
            async (j, body, token) =>
            {
                try
                {
                    await updates.UpdateJobAsync(j, body, token).ConfigureAwait(false);
                    return WriteResult.Done;
                }
                catch (GatewayException e)
                {
                    return e.Status == 403 ? WriteResult.Refused : WriteResult.Failed(e.Message);
                }
            },
            readOnlyGateway,
            ct).ConfigureAwait(false);
    }

    /// Testable `ReconcileAllAsync` accepting custom job lookup and job write delegates.
    public async Task<(int Changed, List<string> Failed)> ReconcileAllAsync(
        IEnumerable<TilePin> pins,
        string accountId,
        IKeyValueStore store,
        Func<TilePin, CancellationToken, Task<TileCronJob?>> lookupJob,
        Func<TileCronJob, JsonObject, CancellationToken, Task<WriteResult>> writeJob,
        bool readOnlyGateway = false,
        CancellationToken ct = default)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var changed = 0;
        var failed = new List<string>();
        foreach (var pin in pins.Where(p => p.IsPage))
        {
            var job = await lookupJob(pin, ct).ConfigureAwait(false);
            if (job == null || !seen.Add(job.Key)) continue;
            var outcome = await ReconcileAsync(job, accountId, store, writeJob, readOnlyGateway, force: true, ct: ct).ConfigureAwait(false);
            if (outcome.Kind == OutcomeKind.Changed) changed++;
            else if (outcome.Kind == OutcomeKind.Failed && outcome.Reason != null) failed.Add(outcome.Reason);
        }
        if (changed > 0 || failed.Count > 0) NotifyChanged(accountId);
        return (changed, failed);
    }

    /// Reads the bot's active model name (`GET /api/model/info?profile=`, cached 10 minutes) when the roster doesn't say.
    public async Task<string?> BotModelAsync(string profile, string? known, string accountId, GatewaySession? session,
        CancellationToken ct = default)
    {
        if (!string.IsNullOrWhiteSpace(known)) return known.Trim();
        var key = accountId + "|" + profile;
        lock (_lock)
        {
            if (_botModels.TryGetValue(key, out var kept) && DateTimeOffset.UtcNow - kept.At < TimeSpan.FromMinutes(10))
                return kept.Name;
        }
        if (session == null) return null;
        try
        {
            var api = new ModelSettingsApi(session, profile == "default" ? null : profile);
            var info = await api.GetModelInfoAsync(ct).ConfigureAwait(false);
            var name = string.IsNullOrWhiteSpace(info.Model) ? null : ModelNames.DisplayModelName(info.Model);
            lock (_lock) _botModels[key] = (name, DateTimeOffset.UtcNow);
            return name;
        }
        catch (Exception)
        {
            lock (_lock) _botModels[key] = (null, DateTimeOffset.UtcNow);
            return null;
        }
    }

    /// Account's starred & recent models; when none, falls back to the bot's ready provider catalog (cached 10 minutes).
    public async Task<List<TileModelPick>> ShortListAsync(string accountId, string profile, IKeyValueStore prefsStore,
        GatewaySession? session, TileModelPick? keep, CancellationToken ct = default)
    {
        var prefs = new ModelPrefs(accountId, prefsStore);
        var favorites = prefs.Favorites;
        var recents = prefs.Recents.Select(r => new TileModelPick(r.Provider, r.Id)).ToList();
        var catalog = new List<TileModelPick>();
        if (favorites.Count == 0 && recents.Count == 0 && session != null)
        {
            var key = accountId + "|" + profile;
            bool cached;
            lock (_lock)
            {
                cached = _catalogs.TryGetValue(key, out var kept) && DateTimeOffset.UtcNow - kept.At < TimeSpan.FromMinutes(10);
                if (cached) catalog = kept.Picks;
            }
            if (!cached)
            {
                try
                {
                    var api = new ModelSettingsApi(session, profile == "default" ? null : profile);
                    var rows = await api.GetModelOptionsAsync(ct).ConfigureAwait(false);
                    var ready = rows.Where(r => r.IsReady).ToList();
                    var first = ready.FirstOrDefault(r => r.IsCurrent) ?? ready.FirstOrDefault();
                    if (first != null)
                        catalog = first.Models.Take(6).Select(m => new TileModelPick(first.Slug, m)).ToList();
                    lock (_lock) _catalogs[key] = (catalog, DateTimeOffset.UtcNow);
                }
                catch (Exception) { }
            }
        }
        return TileModels.ShortList(favorites, recents, catalog, keep);
    }
}
