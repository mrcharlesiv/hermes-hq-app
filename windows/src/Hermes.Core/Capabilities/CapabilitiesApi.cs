using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Capabilities;

/// Skills, Tools, Connectors and Plugins for one bot (HermesKit/Store/CapabilitiesStore.swift, +More, McpCatalog):
/// the gateway's REST routes scoped with `?profile=<bot>`, and the MCP and plugin RPCs with a `profile` param. Writes go
/// one at a time per bot (the gateway saves one list per profile), and only the params each method lists are ever
/// sent (an unknown param is refused with 4000).
public sealed class CapabilitiesApi(GatewaySession session, RpcConnection rpc)
{
    public GatewaySession Session { get; } = session;
    public RpcConnection Rpc { get; } = rpc;

    /// The read-only testing switch: every write here refuses.
    public bool ReadOnly { get; set; }
    /// Install / uninstall / setup polling cadence (`POLL_MS`).
    public TimeSpan PollInterval { get; set; } = TimeSpan.FromMilliseconds(1200);
    /// Disk cache for per-bot `plugins.manage list` reads (6-hour TTL).
    public PluginListCache PluginLists { get; set; } = PluginListCache.Shared;
    /// Clock used for timeout-backoff tracking (overridable in unit tests).
    public Func<DateTimeOffset> PluginListNow { get; set; } = () => DateTimeOffset.UtcNow;
    /// Optional RPC override for deterministic unit tests.
    internal Func<string, JsonObject, TimeSpan, CancellationToken, Task<JsonNode>>? RpcOverride { get; set; }

    /// How long automatic background plugin sweeps back off after a `plugins.manage list` timeout.
    public static readonly TimeSpan PluginListTimeoutBackoff = TimeSpan.FromMinutes(15);

    private sealed class PluginListFlight(long id, int generation, CancellationTokenSource cts)
    {
        public long Id { get; } = id;
        public int Generation { get; } = generation;
        public CancellationTokenSource Cts { get; } = cts;
        public HashSet<Guid> Waiters { get; } = [];
        public Task<List<PluginInfo>> Task { get; set; } = null!;
    }

    private readonly ConcurrentDictionary<string, SemaphoreSlim> _tails = new();
    private readonly object _pluginListGate = new();
    private readonly Dictionary<string, PluginListFlight> _pluginListFlights = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> _pluginListGeneration = new(StringComparer.Ordinal);
    private long _nextPluginListFlightId;
    private Task _pluginListTail = Task.CompletedTask;
    private DateTimeOffset? _pluginListTimedOutAt;

    private static KeyValuePair<string, string>[] Q(string profile, params (string, string)[] extra) =>
        [.. extra.Select(e => KeyValuePair.Create(e.Item1, e.Item2)), KeyValuePair.Create("profile", profile)];

    public static string Encode(string segment) => Uri.EscapeDataString(segment);

    private void Refuse(string title)
    {
        if (ReadOnly) throw new CapabilityException(title, CapabilityException.ReadOnlyReason);
    }

    /// Writes for one bot run one after another.
    public async Task<T> Serial<T>(string profile, Func<Task<T>> work)
    {
        var gate = _tails.GetOrAdd(profile, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync();
        try { return await work(); }
        finally { gate.Release(); }
    }

    public Task Serial(string profile, Func<Task> work) => Serial(profile, async () => { await work(); return true; });

    private async Task<JsonNode?> Rest(HttpMethod method, string path, string profile, (string, string)[]? extra = null,
        JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var a = await Session.SendAsync(method, path, Q(profile, extra ?? []), body, timeout, ct: ct);
        if (!a.Ok) throw GatewaySession.HttpError(a);
        if (a.Body.Trim().Length == 0) return null;
        return a.Json ?? throw new GatewayException("not-hermes", "The gateway sent something that isn't JSON.", a.Status);
    }

    private Task<JsonNode> Call(string method, JsonObject p, int seconds = 30, CancellationToken ct = default) =>
        Call(method, p, TimeSpan.FromSeconds(seconds), ct);

    private Task<JsonNode> Call(string method, JsonObject p, TimeSpan timeout, CancellationToken ct = default) =>
        RpcOverride != null ? RpcOverride(method, p, timeout, ct) : Rpc.RequestAsync(method, p, timeout, ct);

    // ---------------------------------------------------------------- Skills

    public async Task<List<SkillInfo>> SkillsAsync(string profile, CancellationToken ct = default) =>
        [.. ((await Rest(HttpMethod.Get, "/api/skills", profile, ct: ct)) as JsonArray ?? []).Select(SkillInfo.Read).OfType<SkillInfo>()];

    public async Task<List<OfficialSkill>> OfficialSkillsAsync(string profile, CancellationToken ct = default)
    {
        var v = await Rest(HttpMethod.Get, "/api/skills/hub/official", profile, ct: ct);
        return [.. (v.Arr("skills") ?? []).Select(r => r.Text("name") is { } n && r.Text("identifier") is { } id
            ? new OfficialSkill(n, r.Str("description") ?? "", id, r.Text("category"), r.Bool("installed") ?? false) : null).OfType<OfficialSkill>()];
    }

    /// `GET /api/skills/hub/search?q=`: every configured hub source, deduped by identifier (the gateway gives up on a slow
    /// source after 30 s, so the read waits a little longer).
    public async Task<HubSearchResult> SearchHubAsync(string query, string profile, CancellationToken ct = default) =>
        DecodeHub(await Rest(HttpMethod.Get, "/api/skills/hub/search", profile, [("q", query), ("limit", "20")], timeout: TimeSpan.FromSeconds(45), ct: ct));

    public static HubSearchResult DecodeHub(JsonNode? v)
    {
        var seen = new HashSet<string>();
        var results = new List<HubSkill>();
        foreach (var r in v.Arr("results") ?? [])
        {
            if (r.Text("name") is not { } n || r.Text("identifier") is not { } id || !seen.Add(id)) continue;
            results.Add(new(n, r.Str("description") ?? "", id, r.Text("source") ?? "", r.Text("trust_level") ?? "community", r.Text("repo")));
        }
        var installed = (v.Obj("installed") ?? []).Select(p => p.Key).ToHashSet();
        return new(results, installed);
    }

    public async Task<string> SkillContentAsync(string name, string profile, CancellationToken ct = default) =>
        (await Rest(HttpMethod.Get, "/api/skills/content", profile, [("name", name)], ct: ct)).Str("content") ?? "";

    public Task SetSkillAsync(string name, bool enabled, string profile)
    {
        Refuse($"Couldn’t Change {name}");
        return Serial(profile, () => Rest(HttpMethod.Put, "/api/skills/toggle", profile, body: new JsonObject { ["name"] = name, ["enabled"] = enabled }));
    }

    /// Lock/unlock a skill against agent edits (`PUT /api/skills/lock`, Hermes 0.23.4+).
    public Task SetSkillLockedAsync(string name, bool locked, string profile)
    {
        Refuse($"Couldn’t Change {name}");
        return Serial(profile, () => Rest(HttpMethod.Put, "/api/skills/lock", profile, body: new JsonObject { ["name"] = name, ["locked"] = locked }));
    }

    /// Hub-installed skills with an upstream update (`GET /api/skills/hub/updates`, 120 s timeout).
    public async Task<List<SkillHubUpdate>> SkillUpdatesAsync(string profile, CancellationToken ct = default)
    {
        var v = await Rest(HttpMethod.Get, "/api/skills/hub/updates", profile, timeout: TimeSpan.FromSeconds(120), ct: ct);
        var seen = new HashSet<string>();
        var list = new List<SkillHubUpdate>();
        foreach (var r in v.Arr("updates") ?? [])
        {
            if (r.Text("name") is not { } n) continue;
            var id = r.Text("identifier") ?? n;
            if (!seen.Add(id)) continue;
            list.Add(new SkillHubUpdate(n, id, r.Text("source") ?? ""));
        }
        return list;
    }

    /// `POST /api/skills/hub/update` then polls `/api/actions/{name}/status` until it finishes.
    public IAsyncEnumerable<ActionStatus> UpdateSkillsAsync(string profile, CancellationToken ct = default) =>
        Action(profile, "/api/skills/hub/update", new JsonObject(), 200, null, ct);

    /// `POST /api/skills/hub/install {identifier}` then the action's status every 1.2 s until it ends.
    public IAsyncEnumerable<ActionStatus> InstallAsync(string identifier, string profile, CancellationToken ct = default) =>
        Action(profile, "/api/skills/hub/install", new JsonObject { ["identifier"] = identifier }, 200, null, ct);

    public IAsyncEnumerable<ActionStatus> UninstallAsync(string name, string profile, CancellationToken ct = default) =>
        Action(profile, "/api/skills/hub/uninstall", new JsonObject { ["name"] = name }, 200, null, ct);

    private async IAsyncEnumerable<ActionStatus> Action(string profile, string path, JsonNode body, int lines, TimeSpan? ceiling,
        [EnumeratorCancellation] CancellationToken ct)
    {
        Refuse("");
        var started = await Rest(HttpMethod.Post, path, profile, body: body, ct: ct);
        var name = started.Text("name") ?? throw new GatewayException("http", "The gateway answered 500.", 500, "no action name");
        var deadline = ceiling is { } c ? DateTimeOffset.UtcNow + c : DateTimeOffset.MaxValue;
        while (!ct.IsCancellationRequested)
        {
            var raw = await Rest(HttpMethod.Get, $"/api/actions/{Encode(name)}/status", profile, [("lines", lines.ToString())], ct: ct);
            var status = ActionStatus.Read(raw, name);
            yield return status;
            if (!status.Running) yield break;
            if (DateTimeOffset.UtcNow >= deadline)
                throw new CapabilityException("", $"The setup is taking too long. Check {HostWord.Phrase}.");
            await Task.Delay(PollInterval, ct);
        }
    }

    // ---------------------------------------------------------------- Tools (§4)

    public async Task<List<Toolset>> ToolsetsAsync(string profile, CancellationToken ct = default) =>
        [.. ((await Rest(HttpMethod.Get, "/api/tools/toolsets", profile, ct: ct)) as JsonArray ?? []).Select(Toolset.Read).OfType<Toolset>()];

    public Task SetToolsetAsync(string name, bool enabled, string profile)
    {
        Refuse($"Couldn’t Update {name}");
        return Serial(profile, () => Rest(HttpMethod.Put, $"/api/tools/toolsets/{Encode(name)}", profile, body: new JsonObject { ["enabled"] = enabled }));
    }

    /// Calls per tool name over the last year. Best effort: the caller ignores a failure.
    public async Task<Dictionary<string, int>> ToolUsageAsync(string profile, CancellationToken ct = default)
    {
        var v = await Rest(HttpMethod.Get, "/api/analytics/usage", profile, [("days", "365")], ct: ct);
        var o = new Dictionary<string, int>();
        foreach (var row in v.Arr("tools") ?? [])
            if (row.Text("tool") is { } t && SkillUsage.Read(row.Get("count")) is { } n) o[t] = n;
        return o;
    }

    /// null: this gateway's Hermes has no tool setup routes (404).
    public async Task<ToolsetConfig?> ToolsetConfigAsync(string name, string profile, CancellationToken ct = default)
    {
        try { return ToolsetConfig.Read(await Rest(HttpMethod.Get, $"/api/tools/toolsets/{Encode(name)}/config", profile, ct: ct)); }
        catch (GatewayException e) when (CapabilitiesWords.IsNotFound(e)) { return null; }
    }

    /// True when the gateway says the provider needs a Nous sign-in before it works.
    public Task<bool> SelectProviderAsync(string toolset, string provider, string? capability, string profile)
    {
        Refuse($"Couldn’t Select {provider}");
        return Serial(profile, async () =>
        {
            var body = new JsonObject { ["provider"] = provider };
            if (capability != null) body["capability"] = capability;
            return (await Rest(HttpMethod.Put, $"/api/tools/toolsets/{Encode(toolset)}/provider", profile, body: body)).Bool("needs_nous_auth") ?? false;
        });
    }

    public async Task<ToolModels?> ToolModelsAsync(string toolset, string provider, string profile)
    {
        try { return ToolModels.Read(await Rest(HttpMethod.Get, $"/api/tools/toolsets/{Encode(toolset)}/models", profile, [("provider", provider)])); }
        catch (GatewayException e) when (CapabilitiesWords.IsNotFound(e)) { return null; }
    }

    public Task SetToolModelAsync(string toolset, string model, string provider, string profile)
    {
        Refuse($"Couldn’t Select {model}");
        return Serial(profile, () => Rest(HttpMethod.Put, $"/api/tools/toolsets/{Encode(toolset)}/model", profile,
            body: new JsonObject { ["model"] = model, ["provider"] = provider }));
    }

    public async Task<List<TerminalBackend>> TerminalBackendsAsync(string profile)
    {
        var v = await Rest(HttpMethod.Get, "/api/tools/terminal/backends", profile);
        var active = v.Text("active");
        return [.. (v.Arr("backends") ?? []).Select(r => r.Text("name") is { } n
            ? new TerminalBackend(n, r.Text("label") ?? n, r.Str("description") ?? "", r.Bool("active") ?? n == active, r.Text("status") ?? "ready", r.Str("detail") ?? "")
            : null).OfType<TerminalBackend>()];
    }

    public Task SetTerminalBackendAsync(string name, string profile)
    {
        Refuse($"Couldn’t Select {name}");
        return Serial(profile, () => Rest(HttpMethod.Put, "/api/tools/terminal/backend", profile, body: new JsonObject { ["backend"] = name }));
    }

    /// `POST …/post-setup {key}` then the action's status every 1.2 s until it ends, or for 10 minutes.
    public IAsyncEnumerable<ActionStatus> PostSetupAsync(string toolset, string key, string profile, CancellationToken ct = default) =>
        Action(profile, $"/api/tools/toolsets/{Encode(toolset)}/post-setup", new JsonObject { ["key"] = key }, 300, TimeSpan.FromMinutes(10), ct);

    // ---------------------------------------------------------------- Per-bot env (tool keys, plugin secrets)

    public Task SetEnvAsync(string key, string value, string profile)
    {
        Refuse($"Couldn’t Save {key}");
        return Serial(profile, () => Rest(HttpMethod.Put, "/api/env", profile, body: new JsonObject { ["key"] = key, ["value"] = value }));
    }

    /// A key that is already gone (404) counts as removed.
    public Task DeleteEnvAsync(string key, string profile)
    {
        Refuse($"Couldn’t Remove {key}");
        return Serial(profile, async () =>
        {
            try { await Rest(HttpMethod.Delete, "/api/env", profile, body: new JsonObject { ["key"] = key }); }
            catch (GatewayException e) when (CapabilitiesWords.IsNotFound(e)) { }
        });
    }

    /// The stored value, or null when this bot has none (`POST /api/env/reveal`). Hermes allows 5 of these per 30 s (429).
    public async Task<string?> RevealEnvAsync(string key, string? profile = null, CancellationToken ct = default)
    {
        var query = string.IsNullOrWhiteSpace(profile)
            ? Array.Empty<KeyValuePair<string, string>>()
            : [KeyValuePair.Create("profile", profile)];
        var answer = await Session.SendAsync(HttpMethod.Post, "/api/env/reveal", query, new JsonObject { ["key"] = key }, ct: ct)
            .ConfigureAwait(false);
        if (answer.Status == 404) return null;
        if (!answer.Ok) throw GatewaySession.HttpError(answer);
        if (answer.Body.Trim().Length == 0) return null;
        var json = answer.Json ?? throw new GatewayException("not-hermes", "The gateway sent something that isn't JSON.", answer.Status);
        return json.Text("value");
    }

    // ---------------------------------------------------------------- Connectors (§5)

    public async Task<List<McpServer>> McpServersAsync(string profile, CancellationToken ct = default)
    {
        var v = await Call("mcp.servers.list", new JsonObject { ["profile"] = profile }, 30, ct);
        return [.. (v.Arr("servers") ?? []).Select(McpServer.Read).OfType<McpServer>().OrderBy(s => s.Name, StringComparer.CurrentCultureIgnoreCase)];
    }

    public async Task<Dictionary<string, (string Status, int Tools)>> McpStatusAsync(string profile, CancellationToken ct = default)
    {
        var v = await Call("mcp.servers.status", new JsonObject { ["profile"] = profile }, 30, ct);
        var o = new Dictionary<string, (string, int)>();
        foreach (var row in v.Arr("servers") ?? [])
        {
            if (row.Text("name") is not { } n) continue;
            var tools = row.Get("tools") is JsonArray a ? a.Count : (int)(row.Int("tools") ?? 0);
            o[n] = (row.Text("status") ?? "configured", Math.Max(0, tools));
        }
        return o;
    }

    /// Both reads, with the live status folded into the list.
    public async Task<List<McpServer>> ServersWithStatusAsync(string profile, CancellationToken ct = default)
    {
        var statusRead = McpStatusAsync(profile, ct);
        // Observe any fault on the parallel status read even if McpServersAsync throws (e.g., read-only gateways).
        _ = statusRead.ContinueWith(static t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously);
        var list = await McpServersAsync(profile, ct);
        Dictionary<string, (string Status, int Tools)>? status = null;
        try { status = await statusRead; } catch (Exception) when (!ct.IsCancellationRequested) { }
        return status == null ? list : Fold(list, status);
    }

    public static List<McpServer> Fold(IEnumerable<McpServer> list, IReadOnlyDictionary<string, (string Status, int Tools)> status) =>
        [.. list.Select(s => status.TryGetValue(s.Name, out var row) ? s with { Status = row.Status, Tools = row.Tools } : s)];

    /// The one-key route, then `reload.mcp {"confirm": true}` (no `profile`: `ReloadMcpParams` has none).
    public Task SetMcpAsync(string name, bool enabled, string profile)
    {
        Refuse($"Couldn’t Change {name}");
        return Serial(profile, async () =>
        {
            await Rest(HttpMethod.Put, $"/api/mcp/servers/{Encode(name)}/enabled", profile, body: new JsonObject { ["enabled"] = enabled });
            await ReloadMcpAsync();
        });
    }

    public async Task<bool> ReloadMcpAsync()
    {
        try { await Call("reload.mcp", new JsonObject { ["confirm"] = true }); return true; }
        catch (Exception) { return false; }
    }

    /// `mcp.servers.add`. `bearer` goes in `bearer_token`, never inside `config`.
    public Task McpAddAsync(string name, JsonObject config, string? bearer, string profile)
    {
        Refuse($"Couldn’t Add {name}");
        return Serial(profile, async () =>
        {
            var p = new JsonObject { ["profile"] = profile, ["name"] = name, ["config"] = config.DeepClone() };
            if (!string.IsNullOrEmpty(bearer)) p["bearer_token"] = bearer;
            await Call("mcp.servers.add", p);
        });
    }

    /// `mcp.servers.remove`; a server that is already gone (4064) counts as removed.
    public Task McpRemoveAsync(string name, string profile)
    {
        Refuse($"Couldn’t Remove {name}");
        return Serial(profile, async () =>
        {
            try { await Call("mcp.servers.remove", new JsonObject { ["profile"] = profile, ["name"] = name }); }
            catch (GatewayException e) when (e.Code == "rpc" && e.RpcCode == 4064) { }
        });
    }

    public async Task<McpProbe> McpTestAsync(string name, string profile) =>
        McpProbe.Read(await Call("mcp.servers.test", new JsonObject { ["profile"] = profile, ["name"] = name }, 60));

    /// The server's own entry from `GET /api/config` (`mcp_servers[name]`). null: not in the gateway's configuration.
    public async Task<JsonNode?> McpEntryAsync(string name, string profile)
    {
        var a = await Session.SendAsync(HttpMethod.Get, "/api/config", Q(profile));
        if (!a.Ok) throw GatewaySession.HttpError(a);
        if (a.Body.Length > 4 * 1024 * 1024 || a.Json is not JsonObject value)
            throw new CapabilityException("", "Your gateway’s answer wasn’t a configuration.");
        if (value.Get("mcp_servers") is not { } servers) return null;
        if (servers is not JsonObject map) throw new CapabilityException("", "Your gateway’s answer wasn’t a configuration.");
        return map.Get(name) is JsonObject entry ? entry.DeepClone() : null;
    }

    /// Whether the add-on on this computer enforces connector asking levels (`toolPermissions` in its status,
    /// hermes-hq-push 0.9.86+) and whether Hermes can ask interactively (`toolPermissionsAsk`).
    public async Task<(bool Enforced, bool Asks)> AddOnToolLevelsAsync(CancellationToken ct = default)
    {
        try
        {
            var answer = await Session.SendAsync(HttpMethod.Get, Notifications.PushPolicy.PluginRoute + "/status",
                timeout: TimeSpan.FromSeconds(15), ct: ct).ConfigureAwait(false);
            if (!answer.Ok || answer.Json is not JsonObject body) return (false, true);
            return (Notifications.PushPolicy.ToolPermissions(body), Notifications.PushPolicy.ToolPermissionsAsk(body));
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            return (false, true);
        }
    }

    public async Task<bool> AddOnEnforcesToolLevelsAsync(CancellationToken ct = default) =>
        (await AddOnToolLevelsAsync(ct).ConfigureAwait(false)).Enforced;

    /// §5.5-b: read the entry fresh, apply the rules, remove, add; one rollback when the add fails. All inside the bot's
    /// serial queue so no other write of this app lands in between.
    public Task<ToolRulesOutcome> SaveToolRulesAsync(string name, IReadOnlyList<string> disabled, IReadOnlyList<string> discovered, string profile) =>
        SaveToolEntryAsync(name, profile, old => McpToolFilter.SetDisabled(old, disabled, discovered));

    /// Saves granular per-tool connector permissions (Always allow / Auto-review / Needs approval / Blocked) atomically.
    public Task<ToolRulesOutcome> SaveToolPoliciesAsync(string name, IReadOnlyDictionary<string, McpToolPermission> permissions,
        IReadOnlyList<string> discovered, string profile) =>
        SaveToolEntryAsync(name, profile, old => McpToolFilter.SetPermissions(old, permissions, discovered));

    private Task<ToolRulesOutcome> SaveToolEntryAsync(string name, string profile, Func<JsonNode, JsonNode> transform)
    {
        Refuse("Couldn’t Save");
        return Serial<ToolRulesOutcome>(profile, async () =>
        {
            if (await McpEntryAsync(name, profile) is not { } old) return new ToolRulesOutcome.Gone();
            if (McpToolFilter.LooksRedacted(old))
                throw new CapabilityException("Couldn’t Save", $"This connector’s tool list can be changed on {HostWord.Phrase}.");
            var next = transform(old);
            if (JsonNode.DeepEquals(next, old)) return new ToolRulesOutcome.Unchanged();
            await Call("mcp.servers.remove", new JsonObject { ["profile"] = profile, ["name"] = name });
            try
            {
                await Call("mcp.servers.add", new JsonObject { ["profile"] = profile, ["name"] = name, ["config"] = next.DeepClone() });
            }
            catch (Exception e)
            {
                var reason = CapabilitiesWords.Detail(e);
                try { await Call("mcp.servers.add", new JsonObject { ["profile"] = profile, ["name"] = name, ["config"] = old.DeepClone() }); }
                catch (Exception) { return new ToolRulesOutcome.Lost(reason); }
                await ReloadMcpAsync();
                return new ToolRulesOutcome.RolledBack(reason);
            }
            await ReloadMcpAsync();
            return new ToolRulesOutcome.Saved();
        });
    }

    /// Lines of a gateway log file. Throws an http 400/404 when the gateway keeps no such file.
    public async Task<List<string>> LogsAsync(string file, int lines, string? search, string profile)
    {
        var extra = new List<(string, string)> { ("file", file), ("lines", lines.ToString()) };
        if (!string.IsNullOrEmpty(search)) extra.Add(("search", search));
        return [.. ((await Rest(HttpMethod.Get, "/api/logs", profile, [.. extra])).Arr("lines") ?? []).Select(l => J.AsString(l) ?? "")];
    }

    public async Task<McpOAuthStart> OAuthStartAsync(string name, string redirect, string profile)
    {
        var v = await Call("mcp.servers.oauth.start", new JsonObject { ["profile"] = profile, ["name"] = name, ["client_redirect_uri"] = redirect });
        return new(v.Str("session_id") ?? "", v.Str("auth_url") ?? "");
    }

    /// Sends `code`/`state` or `error`; `iss` only when present.
    public async Task OAuthCallbackAsync(string name, string sessionId, LoopbackRelay.Callback callback, string profile)
    {
        var p = new JsonObject { ["profile"] = profile, ["name"] = name, ["session_id"] = sessionId };
        if (!string.IsNullOrEmpty(callback.Error)) p["error"] = callback.Error;
        else if (callback.Code != null) p["code"] = callback.Code;
        if (callback.State != null) p["state"] = callback.State;
        if (!string.IsNullOrEmpty(callback.Iss)) p["iss"] = callback.Iss;
        await Call("mcp.servers.oauth.callback", p);
    }

    public async Task<McpOAuthPoll> OAuthPollAsync(string name, string sessionId, string profile)
    {
        var v = await Call("mcp.servers.oauth.poll", new JsonObject { ["profile"] = profile, ["name"] = name, ["session_id"] = sessionId }, 10);
        return new(v.Text("status") ?? "pending", v.Str("error_message") ?? "", v.Arr("tools")?.Count ?? 0);
    }

    public async Task OAuthCancelAsync(string name, string sessionId, string profile)
    {
        try { await Call("mcp.servers.oauth.cancel", new JsonObject { ["profile"] = profile, ["name"] = name, ["session_id"] = sessionId }, 10); }
        catch (Exception) { }
    }

    /// null when the gateway predates the catalog route (404, or the web page instead of JSON).
    public async Task<List<McpCatalogEntry>?> McpCatalogAsync(string profile)
    {
        var a = await Session.SendAsync(HttpMethod.Get, "/api/mcp/catalog", Q(profile));
        if (a.Status == 404) return null;
        if (!a.Ok) throw GatewaySession.HttpError(a);
        return a.Json is JsonObject v && v.Get("entries") != null ? McpCatalog.Entries(v) : null;
    }

    /// Installs one catalog entry with the keys it declares; an entry built from a git repository runs as a background
    /// action polled until it ends. Returns when the server is in the bot's config.
    public async Task InstallCatalogAsync(string name, IReadOnlyDictionary<string, string> env, string profile)
    {
        if (ReadOnly) throw new CapabilityException("Couldn’t Install", CapabilityException.ReadOnlyReason);
        var envObj = new JsonObject();
        foreach (var (k, v) in env) envObj[k] = v;
        var started = await Rest(HttpMethod.Post, "/api/mcp/catalog/install", profile, body: new JsonObject { ["name"] = name, ["env"] = envObj, ["enable"] = true });
        if (started.Bool("background") != true || started.Text("action") is not { } action)
        {
            await ReloadMcpAsync();
            return;
        }
        var deadline = DateTimeOffset.UtcNow.AddMinutes(10);
        while (DateTimeOffset.UtcNow < deadline)
        {
            await Task.Delay(PollInterval);
            var status = ActionStatus.Read(await Rest(HttpMethod.Get, $"/api/actions/{Encode(action)}/status", profile, [("lines", "1")]), action);
            if (status.Running) continue;
            if (status.ExitCode != 0)
                throw new CapabilityException("", "The install didn’t finish. See why on the computer running Hermes.");
            await ReloadMcpAsync();
            return;
        }
        throw new CapabilityException("", "The install is taking more than 10 minutes. It may still finish on the computer running Hermes.");
    }

    // ---------------------------------------------------------------- Plugins (§9)

    /// True when `error` indicates a gateway timeout (used for plugin-list backoff and sweep early-stop).
    public static bool IsTimeout(Exception error) =>
        error is TimeoutException
        || error is GatewayException { Code: "timeout" }
        || error is GatewayException { IsNotConnected: true, NotSentBecause: "timeout" };

    /// True if a `plugins.manage list` call timed out within `window` (default 15 minutes).
    public bool PluginListTimedOutRecently(TimeSpan? window = null)
    {
        lock (_pluginListGate)
        {
            if (_pluginListTimedOutAt is not { } at) return false;
            var age = PluginListNow() - at;
            var limit = window ?? PluginListTimeoutBackoff;
            return age >= TimeSpan.Zero && age < limit;
        }
    }

    /// Marks any in-flight `plugins.manage list` for `profile` stale so its late answer cannot overwrite fresh state.
    public void InvalidatePluginListFlight(string profile)
    {
        lock (_pluginListGate)
        {
            _pluginListGeneration[profile] = _pluginListGeneration.GetValueOrDefault(profile) + 1;
            _pluginListFlights.Remove(profile);
        }
    }

    /// Reads one bot's plugin list: concurrent callers for the same profile join one in-flight RPC; distinct profiles
    /// chain one at a time so slow gateways are not saturated. Successful reads update `PluginLists` and
    /// `PluginUpdateReminder`; timeouts record `PluginListTimeoutBackoff`.
    public async Task<List<PluginInfo>> PluginsAsync(string profile, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        PluginListFlight flight;
        var waiterId = Guid.NewGuid();
        lock (_pluginListGate)
        {
            if (_pluginListFlights.TryGetValue(profile, out var existing))
            {
                flight = existing;
            }
            else
            {
                var id = ++_nextPluginListFlightId;
                var generation = _pluginListGeneration.GetValueOrDefault(profile);
                var flightCts = new CancellationTokenSource();
                var previous = _pluginListTail;
                var created = new PluginListFlight(id, generation, flightCts);
                created.Task = RunPluginListFlightAsync(profile, id, generation, previous, flightCts.Token);
                _pluginListTail = AwaitQuietlyAsync(created.Task);
                _pluginListFlights[profile] = created;
                flight = created;
            }
            flight.Waiters.Add(waiterId);
        }

        try
        {
            return await flight.Task.WaitAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            DetachPluginListWaiter(profile, flight, waiterId);
        }
    }

    private void DetachPluginListWaiter(string profile, PluginListFlight flight, Guid waiterId)
    {
        var shouldCancel = false;
        lock (_pluginListGate)
        {
            if (flight.Waiters.Remove(waiterId) && flight.Waiters.Count == 0)
            {
                if (_pluginListFlights.TryGetValue(profile, out var cur) && cur.Id == flight.Id)
                    _pluginListFlights.Remove(profile);
                shouldCancel = !flight.Task.IsCompleted;
            }
        }
        if (shouldCancel)
        {
            try { flight.Cts.Cancel(); } catch (ObjectDisposedException) { }
        }
    }

    private async Task<List<PluginInfo>> RunPluginListFlightAsync(string profile, long id, int generation, Task previous, CancellationToken flightCt)
    {
        try
        {
            await previous.ConfigureAwait(false);
            flightCt.ThrowIfCancellationRequested();
            var v = await Call("plugins.manage", new JsonObject { ["action"] = "list", ["profile"] = profile }, TimeSpan.FromSeconds(30), flightCt)
                .ConfigureAwait(false);
            var arr = v.Arr("plugins");
            var list = (arr ?? []).Select(PluginInfo.Read).OfType<PluginInfo>().ToList();
            bool sameGeneration;
            lock (_pluginListGate)
            {
                _pluginListTimedOutAt = null;
                sameGeneration = arr != null && _pluginListGeneration.GetValueOrDefault(profile) == generation;
            }
            if (sameGeneration)
            {
                var account = Session.Account.Key;
                PluginLists.Store(list, account, profile);
                PluginUpdateReminder.Report(account, profile, ReadOnly ? Array.Empty<PluginInfo>() : list);
            }
            return list;
        }
        catch (Exception ex)
        {
            if (IsTimeout(ex))
            {
                lock (_pluginListGate) _pluginListTimedOutAt = PluginListNow();
            }
            throw;
        }
        finally
        {
            lock (_pluginListGate)
            {
                if (_pluginListFlights.TryGetValue(profile, out var cur) && cur.Id == id)
                    _pluginListFlights.Remove(profile);
            }
        }
    }

    private static async Task AwaitQuietlyAsync(Task task)
    {
        try { await task.ConfigureAwait(false); } catch (Exception) { }
    }

    public async Task<PluginResult> PluginAsync(PluginAction action, string profile)
    {
        Refuse("");
        InvalidatePluginListFlight(profile);
        try
        {
            return await Serial(profile, async () =>
                PluginResult.Read(await Call("plugins.manage", action.Params(profile), action.Timeout).ConfigureAwait(false)))
                .ConfigureAwait(false);
        }
        finally
        {
            InvalidatePluginListFlight(profile);
            PluginLists.Forget(Session.Account.Key, profile);
        }
    }
}
