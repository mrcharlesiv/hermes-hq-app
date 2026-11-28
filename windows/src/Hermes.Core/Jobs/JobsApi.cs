using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Jobs;

/// The Jobs page's REST calls (docs/spec/1x-pages.md §3.1, docs/spec/3x-jobs.md §3), each naming the job's own profile.
public class JobsApi(GatewaySession session)
{
    public const string ListPath = "/api/cron/jobs";
    public const string BotWorkingPath = "/api/plugins/hermes-hq-push/cron/working";

    public GatewaySession Session { get; } = session;

    /// The shared cache keyed by the session; a session-less instance (tests) keeps its own.
    private JobsListCache? _ownCache;
    internal JobsListCache Cache => Session is { } s ? JobsListCache.For(s) : (_ownCache ??= new JobsListCache());

    public static string JobPath(string id) => ListPath + "/" + Uri.EscapeDataString(id);

    private static List<KeyValuePair<string, string>> Profile(string? profile) =>
        profile == null ? [] : [new("profile", profile)];

    /// One request; a refusal throws the gateway's GatewayException ("http" with its status and body).
    public virtual async Task<JsonNode?> SendAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var a = await Session.SendAsync(method, path, query, body, timeout, ct: ct).ConfigureAwait(false);
        if (!a.Ok) throw GatewaySession.HttpError(a);
        return a.Body.Trim().Length == 0 ? null : a.Json;
    }

    /// The list read's cache key: one per scope, shared with the Tiles page's reads of the same session.
    public static string ListKey(string scope) => ListPath + "?profile=" + scope;

    public async Task<List<CronJob>> ListAsync(string scope, CancellationToken ct = default)
    {
        var json = await Cache.ReadAsync(ListKey(scope),
            () => SendAsync(HttpMethod.Get, ListPath, Profile(scope), timeout: TimeSpan.FromSeconds(60), ct: CancellationToken.None), ct).ConfigureAwait(false);
        return CronJob.List(json);
    }

    /// A write's follow-up refresh must not be served the answer read before it.
    public void ForgetList(string scope) => Cache.Forget(ListKey(scope));

    public async Task<JsonNode?> JobAsync(string id, string? profile, TimeSpan? timeout = null, CancellationToken ct = default) =>
        await SendAsync(HttpMethod.Get, JobPath(id), Profile(profile), timeout: timeout, ct: ct).ConfigureAwait(false);

    public async Task<List<CronRun>> RunsAsync(string id, string owner, CancellationToken ct = default) =>
        CronRun.List(await SendAsync(HttpMethod.Get, JobPath(id) + "/runs", [new("limit", "20"), new("profile", owner)], ct: ct).ConfigureAwait(false));

    /// Which jobs' output a bot is still working on (the add-on's `GET cron/working`): job key → status; null when the
    /// add-on isn't there (404); throws for any other failure.
    public async Task<Dictionary<string, string>?> BotWorkingAsync(CancellationToken ct = default)
    {
        try { return BotWorkingMap(await SendAsync(HttpMethod.Get, BotWorkingPath, timeout: TimeSpan.FromSeconds(60), ct: ct).ConfigureAwait(false)); }
        catch (GatewayException e) when (JobErrors.Status(e) == 404) { return null; }
    }

    /// `{"jobs": [{"profile", "id", "status", …}]}` → job key → status.
    public static Dictionary<string, string> BotWorkingMap(JsonNode? json)
    {
        var map = new Dictionary<string, string>();
        foreach (var row in json.Arr("jobs") ?? [])
        {
            if (JobJson.StrictString(row.Get("id")) is not { Length: > 0 } id) continue;
            var profile = JobJson.StrictString(row.Get("profile")) ?? "";
            map[(profile.Length == 0 ? "default" : profile) + "|" + id] = JobJson.StrictString(row.Get("status")) ?? "claimed";
        }
        return map;
    }

    public Task<JsonNode?> PauseAsync(string id, string? owner, bool pause, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Post, JobPath(id) + (pause ? "/pause" : "/resume"), Profile(owner), ct: ct);

    public Task<JsonNode?> DeleteAsync(string id, string owner, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Delete, JobPath(id), Profile(owner), ct: ct);

    /// Run Now (spec 1x §3.6, the web's cron-run-once): reads the job first (nothing runs when that fails); the trigger
    /// answers only when the run ends (up to `timeout`). A paused job is paused again as soon as its activation is seen,
    /// and once more when the trigger settles; `RestorePauseException` when that last pause failed.
    public async Task<CronJob?> RunOnceAsync(string jobId, string? profile, TimeSpan timeout, TimeSpan? pollInterval = null, CancellationToken ct = default)
    {
        var path = JobPath(jobId);
        var beforeJson = await SendAsync(HttpMethod.Get, path, Profile(profile), ct: ct).ConfigureAwait(false);
        var before = CronJob.Parse(beforeJson);
        var ownerName = JobJson.StrictString(beforeJson.Get("profile_name")) is { Length: > 0 } pn ? pn
            : JobJson.StrictString(beforeJson.Get("profile")) is { Length: > 0 } p ? p : profile;
        var owner = Profile(ownerName);
        var paused = before?.Enabled == false || before?.State == "paused";
        var trigger = SendAsync(HttpMethod.Post, path + "/trigger", owner, timeout: timeout, ct: ct);
        if (paused)
        {
            var poll = pollInterval ?? TimeSpan.FromMilliseconds(250);
            while (!trigger.IsCompleted)
            {
                await Task.WhenAny(trigger, Task.Delay(poll, ct)).ConfigureAwait(false);
                if (trigger.IsCompleted) break;
                try
                {
                    var current = await SendAsync(HttpMethod.Get, path, owner, timeout: TimeSpan.FromSeconds(2), ct: ct).ConfigureAwait(false);
                    if (JobJson.StrictBool(current.Get("enabled")) == true && JobJson.StrictString(current.Get("state")) != "paused")
                    {
                        try { await SendAsync(HttpMethod.Post, path + "/pause", owner, ct: ct).ConfigureAwait(false); } catch (GatewayException) { }
                        break;
                    }
                }
                catch (GatewayException) { /* a read failure can't cancel the remote run */ }
            }
        }
        Exception? failure = null;
        JsonNode? answer = null;
        try { answer = await trigger.ConfigureAwait(false); }
        catch (GatewayException e) { failure = e; }
        if (paused)
        {
            try { await SendAsync(HttpMethod.Post, path + "/pause", owner, ct: ct).ConfigureAwait(false); }
            catch (GatewayException e)
            {
                var gone = JobErrors.Status(e) == 404 || (e.Body ?? e.Message).Contains("not found", StringComparison.OrdinalIgnoreCase);
                if (!gone) throw new RestorePauseException(JobErrors.Reason(e));
            }
        }
        if (failure != null) throw failure;
        return CronJob.Parse(answer);
    }

    public Task<JsonNode?> CreateAsync(JsonNode body, string profile, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Post, ListPath, Profile(profile), body, JobsStore.WriteTimeout, ct);

    public Task<JsonNode?> UpdateAsync(string id, string owner, JsonNode updates, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Put, JobPath(id), Profile(owner), new JsonObject { ["updates"] = updates }, JobsStore.WriteTimeout, ct);

    public Task<JsonNode?> InstantiateAsync(string key, IReadOnlyDictionary<string, string> values, string profile, CancellationToken ct = default)
    {
        var v = new JsonObject();
        foreach (var (k, x) in values) v[k] = x;
        return SendAsync(HttpMethod.Post, "/api/cron/blueprints/instantiate", Profile(profile),
            new JsonObject { ["blueprint"] = key, ["values"] = v }, JobsStore.WriteTimeout, ct);
    }

    public async Task<List<DeliveryTarget>> DeliveryTargetsAsync(string profile, CancellationToken ct = default) =>
        DeliveryTarget.List(await SendAsync(HttpMethod.Get, "/api/cron/delivery-targets", Profile(profile), ct: ct).ConfigureAwait(false));

    public async Task<List<JobModelProvider>> ModelProvidersAsync(string profile, CancellationToken ct = default) =>
        JobModelProvider.List(await SendAsync(HttpMethod.Get, "/api/model/options", [new("explicit_only", "1"), new("profile", profile)], ct: ct).ConfigureAwait(false));

    public async Task<List<Blueprint>> BlueprintsAsync(string profile, CancellationToken ct = default) =>
        Blueprint.List(await SendAsync(HttpMethod.Get, "/api/cron/blueprints", Profile(profile), ct: ct).ConfigureAwait(false));

    /// A run's saved output document (`GET /api/fs/download?path=&profile=`), as text.
    public async Task<string> DownloadTextAsync(string path, string profile, CancellationToken ct = default)
    {
        var a = await Session.SendAsync(HttpMethod.Get, "/api/fs/download", [new("path", path), new("profile", profile)], ct: ct).ConfigureAwait(false);
        if (!a.Ok) throw GatewaySession.HttpError(a);
        return a.Body;
    }
}

/// A paused job ran but couldn't be paused again (spec 1x §3.6 step 5).
public sealed class RestorePauseException(string underlying) : Exception("Couldn’t restore the job’s paused state after running. Check its schedule.")
{
    public string Underlying { get; } = underlying;
}

/// A model the editor can pin.
public sealed record JobModelChoice(string Provider, string Model);

/// A provider row of `GET /api/model/options?explicit_only=1` the editor can offer: signed in, with models.
public sealed record JobModelProvider(string Slug, string Name, IReadOnlyList<string> Models)
{
    public static List<JobModelProvider> List(JsonNode? json)
    {
        var seen = new HashSet<string>();
        var out_ = new List<JobModelProvider>();
        foreach (var row in json.Arr("providers") ?? [])
        {
            if (JobJson.PgString(row.Get("slug"))?.Trim() is not { Length: > 0 } slug || !seen.Add(slug)) continue;
            if (JobJson.StrictBool(row.Get("authenticated")) == false) continue;
            var models = new HashSet<string>();
            var listed = (row.Arr("models") ?? []).Select(m => JobJson.StrictString(m)?.Trim()).OfType<string>()
                .Where(m => m.Length > 0 && models.Add(m)).ToList();
            if (listed.Count == 0) continue;
            var name = JobJson.PgString(row.Get("name"))?.Trim() ?? "";
            out_.Add(new JobModelProvider(slug, name.Length == 0 ? slug : name, listed));
        }
        return out_;
    }
}

/// Errors in words (HermesKit/Pages/PagesWire.swift `PagesREST`, JobsStore+editor.swift `editReason`).
public static class JobErrors
{
    public const string OlderHermes = "Not available on this Hermes. Updating Hermes may add it.";
    public const string SlowAnswer = "The gateway is taking a while. Check the list before trying again.";
    public const string NoReason = "The gateway did not say why.";
    public const string MissingRoute = "This Hermes can’t do that yet. Update Hermes, then try again.";
    public static string CantReach => $"Can’t reach {HostWord.Phrase}. Check that it’s on, and that Tailscale is on here too if you use it.";

    public static int? Status(Exception e) => e is GatewayException { Status: > 0 } g ? g.Status : null;

    /// Sent but not answered in time, or a gateway/edge timeout: the work may still be running.
    public static bool IsSlowAnswer(Exception e) => e is GatewayException g && (g.Code == "timeout" || g.Status is 502 or 504 or 524);

    /// `detail` of an HTTP error body (a string, or an object's `message`); null when there is none.
    public static string? Detail(string? body)
    {
        var value = body == null ? null : J.Parse(body);
        if (value == null)
        {
            var text = body?.Trim() ?? "";
            return text.Length == 0 || text.StartsWith('<') || text.Length > 300 ? null : text;
        }
        if (value.Get("detail") is { } detail)
        {
            if (JobJson.StrictString(detail) is { Length: > 0 } t) return t;
            if (JobJson.StrictString(detail.Get("message")) is { Length: > 0 } m) return m;
            return null;
        }
        return JobJson.StrictString(value.Get("error")) is { Length: > 0 } err ? err : null;
    }

    /// A 404/405 for the route itself (a bare "Not Found" / "Method Not Allowed", or no reason at all).
    public static bool IsUnknownRoute(GatewayException e)
    {
        if (e.Status is not (404 or 405)) return false;
        var text = Detail(e.Body)?.Trim().ToLowerInvariant();
        return text == null || text is "not found" or "method not allowed";
    }

    /// The gateway's own reason for a refused request, in words; transport failures their own text.
    public static string Reason(Exception e)
    {
        if (e is RestorePauseException) return e.Message;
        if (e is GatewayException g)
        {
            if (g.Code == "http")
            {
                if (IsUnknownRoute(g)) return OlderHermes;
                return Detail(g.Body) ?? "The gateway couldn’t do that.";
            }
            if (g.Code is "timeout" or "offline") return CantReach;
            return g.Message;
        }
        if (e is OperationCanceledException) return "Cancelled.";
        return "The gateway couldn’t do that.";
    }

    /// A refusal as the editor shows it: the first line of `detail`, at most 200 characters.
    public static string EditReason(Exception e)
    {
        if (IsSlowAnswer(e)) return SlowAnswer;
        if (e is not GatewayException { Code: "http" } g) return Reason(e);
        var line = (Detail(g.Body) ?? "").Split('\n', '\r').FirstOrDefault()?.Trim() ?? "";
        if (line.Length == 0) return NoReason;
        if (g.Status == 404 && line.Equals("not found", StringComparison.OrdinalIgnoreCase)) return MissingRoute;
        return line.Length > 200 ? line[..199].Trim() + "…" : line;
    }
}
