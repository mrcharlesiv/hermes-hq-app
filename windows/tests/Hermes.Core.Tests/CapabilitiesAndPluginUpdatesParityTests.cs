using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Capabilities;
using Hermes.Core.Composer;
using Hermes.Core.Net;
using Hermes.Core.Notifications;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests;

/// Parity tests for Wave 5B:
/// - Clear HQ Plugin Updates (`AddOnChanges`, `AddOnReminder`)
/// - Plugin Update Opt-Out & Serialized One-at-a-Time Reads (`PluginListCache`, `CapabilitiesApi.PluginsAsync`, `PluginUpdateReminder`, `PluginUpdateConsent`)
/// - Connector Tool Levels (`McpToolPermission`, `McpToolFilter`, `CapabilitiesApi.{AddOnToolLevelsAsync, SaveToolPoliciesAsync, RevealEnvAsync}`)
public class CapabilitiesAndPluginUpdatesParityTests
{
    private static JsonNode N(string json) => JsonNode.Parse(json)!;

    private sealed class StubHttpHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public List<(HttpMethod Method, string Path, string Query, string? Body)> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            string? body = null;
            if (request.Content != null) body = await request.Content.ReadAsStringAsync(cancellationToken);
            var uri = request.RequestUri!;
            Requests.Add((request.Method, uri.AbsolutePath, uri.Query, body));
            return respond(request);
        }
    }

    private static HttpResponseMessage JsonResponse(HttpStatusCode status, string json) =>
        new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    private static (GatewaySession Session, RpcConnection Rpc, CapabilitiesApi Api) CreateApi(
        string url = "https://gw.example",
        string username = "alice",
        Func<HttpRequestMessage, HttpResponseMessage>? http = null,
        PluginListCache? cache = null,
        Func<DateTimeOffset>? now = null)
    {
        var handler = new StubHttpHandler(http ?? (_ => JsonResponse(HttpStatusCode.OK, "{}")));
        var account = new StoredAccount(url, username);
        var session = new GatewaySession(GatewayAddress.FromTyped(url), account, new MemoryTokenStore(), handler);
        var rpc = new RpcConnection(session);
        var api = new CapabilitiesApi(session, rpc)
        {
            PluginLists = cache ?? new PluginListCache(Path.Combine(Path.GetTempPath(), "hq-test-plc-" + Guid.NewGuid().ToString("N")), now),
            PluginListNow = now ?? (() => DateTimeOffset.UtcNow),
        };
        return (session, rpc, api);
    }

    // ---------------------------------------------------------------- AddOnChanges & AddOnReminder

    [Fact]
    public void AddOnChangesIdentifiesHQPluginsAndDisplayMetadata()
    {
        Assert.True(AddOnChanges.IsHQPlugin("hermes-hq-push"));
        Assert.True(AddOnChanges.IsHQPlugin("hermes-hq-browser"));
        Assert.True(AddOnChanges.IsHQPlugin("hermes-hq-proactive"));
        Assert.True(AddOnChanges.IsHQPlugin("  HERMES-HQ-FUTURE  "));
        Assert.False(AddOnChanges.IsHQPlugin("web-clipper"));
        Assert.False(AddOnChanges.IsHQPlugin(""));
        Assert.False(AddOnChanges.IsHQPlugin(null));

        Assert.Equal("Hermes HQ Add-on", AddOnChanges.DisplayTitle("hermes-hq-push"));
        Assert.Equal("Browser Add-on", AddOnChanges.DisplayTitle("hermes-hq-browser"));
        Assert.Equal("Proactivity (Beta)", AddOnChanges.DisplayTitle("hermes-hq-proactive"));
        Assert.Equal("Weather Now", AddOnChanges.DisplayTitle("weather-now"));

        Assert.Equal(["hermes-hq-proactive", "Proactivity"], AddOnChanges.CommitAliases("hermes-hq-proactive"));
        Assert.Equal(["hermes-hq-push"], AddOnChanges.CommitAliases("hermes-hq-push"));

        Assert.Equal("0.9.74", AddOnChanges.DefaultTargetVersion("hermes-hq-push"));
        Assert.Equal("3.10.0", AddOnChanges.DefaultTargetVersion("hermes-hq-browser"));
        Assert.Equal("0.4.0-beta.2", AddOnChanges.DefaultTargetVersion("hermes-hq-proactive"));
        Assert.Null(AddOnChanges.DefaultTargetVersion("web-clipper"));

        Assert.Equal(
            "https://api.github.com/repos/mrcharlesiv/hermes-hq-plugins/commits?path=hermes-hq-push&per_page=60",
            AddOnChanges.CommitsUrl("hermes-hq-push")!.ToString());
    }

    [Fact]
    public void AddOnChangesComparesPreReleaseSemverAndDetectsCommitShas()
    {
        Assert.True(AddOnChanges.IsValidVersion("0.9.91"));
        Assert.True(AddOnChanges.IsValidVersion("v0.4.0-beta.2+build.9"));
        Assert.False(AddOnChanges.IsValidVersion(""));
        Assert.False(AddOnChanges.IsValidVersion("0.4.0-"));
        Assert.False(AddOnChanges.IsValidVersion("0.4.0-beta..2"));
        Assert.False(AddOnChanges.IsValidVersion("abc1234"));

        // Stable > pre-release; numeric pre-release ordering; numeric < non-numeric
        Assert.True(AddOnChanges.CompareVersions("0.4.0", "0.4.0-beta.2") > 0);
        Assert.True(AddOnChanges.CompareVersions("0.4.0-beta.10", "0.4.0-beta.2") > 0);
        Assert.True(AddOnChanges.CompareVersions("0.4.0-beta.2", "0.4.0-beta.1") > 0);
        Assert.True(AddOnChanges.CompareVersions("0.4.0-beta.1", "0.3.0-beta.3") > 0);
        Assert.True(AddOnChanges.CompareVersions("0.4.0-1", "0.4.0-beta") < 0);
        Assert.Equal(0, AddOnChanges.CompareVersions("v1.2.0", "1.2"));
        Assert.Null(AddOnChanges.CompareVersions("bad", "1.0.0"));

        Assert.True(AddOnChanges.VersionAtLeast("0.4.0-beta.2", "0.4.0-beta.2"));
        Assert.True(AddOnChanges.VersionAtLeast("0.4.0", "0.4.0-beta.2"));
        Assert.False(AddOnChanges.VersionAtLeast("0.4.0-beta.1", "0.4.0-beta.2"));

        Assert.True(AddOnChanges.IsCommitSha("9f2c1ab"));
        Assert.True(AddOnChanges.IsCommitSha("0123456789abcdef0123456789abcdef01234567"));
        Assert.False(AddOnChanges.IsCommitSha("012345")); // too short
        Assert.False(AddOnChanges.IsCommitSha("0.9.91")); // contains dot
        Assert.False(AddOnChanges.IsCommitSha("zzzzzzz")); // non-hex
        Assert.False(AddOnChanges.IsCommitSha(null));
    }

    [Fact]
    public void AddOnChangesParsesTidiesMergesAndFormatsFallbackSummaries()
    {
        Assert.Equal("After an update the app reads it", AddOnChanges.Tidy("after an update the app reads it; internal details"));
        Assert.Equal("Fixes takeover", AddOnChanges.Tidy("fixes takeover (browser_exec only) (owner 2026-11-23) (hermes-hq-app#413)"));
        Assert.Equal("Turned off entirely", AddOnChanges.Tidy("turned off entirely (tools hidden; rest"));

        string[] subjects =
        [
            "hermes-hq-push 0.9.95: follow-up wording fix",
            "hermes-hq-push 0.9.95: Adds brand new feature; extra detail (issue #12)",
            "hermes-hq-push 0.9.89 & hermes-hq-browser 3.13.1: Joint compatibility update",
            "Proactivity 0.5.0-beta.1: Smarter morning brief",
            "hermes-hq-push 0.9.80: Already installed",
        ];

        var push = AddOnChanges.Changes(subjects, "hermes-hq-push", after: "0.9.88", limit: 10);
        Assert.Equal(2, push.Count);
        Assert.Equal("0.9.95", push[0].Version);
        Assert.Equal("Adds brand new feature", push[0].Line); // older commit for same version wins
        Assert.Equal("0.9.89", push[1].Version);
        Assert.Equal("Joint compatibility update", push[1].Line);

        var browser = AddOnChanges.Changes(subjects, "hermes-hq-browser", after: "3.13.0", limit: 10);
        Assert.Single(browser);
        Assert.Equal("3.13.1", browser[0].Version);

        var proactive = AddOnChanges.Changes(subjects, "hermes-hq-proactive", after: "0.4.0-beta.2", limit: 10);
        Assert.Single(proactive);
        Assert.Equal("0.5.0-beta.1", proactive[0].Version);

        // JSON Parse + Merge with curated notes
        var json = """[{"commit":{"message":"hermes-hq-push 0.9.99: Future release\n\nBody line"}}]""";
        var parsed = AddOnChanges.Parse(json, "hermes-hq-push", after: "0.9.89", limit: 10);
        var merged = AddOnChanges.Merge(parsed, "hermes-hq-push", after: "0.9.89", limit: 10);
        Assert.Equal("0.9.99", merged[0].Version);
        Assert.Equal("0.9.91", merged[1].Version);
        Assert.Equal("0.9.90", merged[2].Version);

        // Curated notes populated for all three first-party plugins
        Assert.NotEmpty(AddOnChanges.BuiltInChanges("hermes-hq-push", after: null));
        Assert.NotEmpty(AddOnChanges.BuiltInChanges("hermes-hq-browser", after: null));
        Assert.NotEmpty(AddOnChanges.BuiltInChanges("hermes-hq-proactive", after: null));

        // BestTargetVersion never prefers a raw commit SHA over a real version
        Assert.Equal("0.4.0-beta.2", AddOnChanges.BestTargetVersion(null, "9f2c1ab", "hermes-hq-proactive"));
        Assert.Equal("0.9.99", AddOnChanges.BestTargetVersion("0.9.99", "0.9.74", "hermes-hq-push"));
        Assert.Equal("0.9.91", AddOnChanges.BestTargetVersion("0.9.80", "0.9.91", "hermes-hq-push"));

        Assert.Equal("0.9.33 → 0.9.40", AddOnChanges.VersionLine("0.9.33", "0.9.40", setUp: false));
        Assert.Equal("0.9.40 · newer build", AddOnChanges.VersionLine("0.9.40", "0.9.40", setUp: false));
        Assert.Equal("New · 0.9.40", AddOnChanges.VersionLine(null, "0.9.40", setUp: true));
        Assert.Equal("To 0.9.40", AddOnChanges.VersionLine(null, "0.9.40", setUp: false));
        Assert.Equal("0.9.33 → newest", AddOnChanges.VersionLine("0.9.33", null, setUp: false));
        Assert.Null(AddOnChanges.VersionLine(null, null, setUp: false));

        Assert.Contains("remaining bots", AddOnChanges.FallbackSummary("hermes-hq-push", "0.9.91", "0.9.91", setUp: false, botsNote: "For Ivy"));
        Assert.Contains("Proactivity (Beta)", AddOnChanges.FallbackSummary("hermes-hq-proactive", null, "0.4.0-beta.2", setUp: true));
    }

    [Fact]
    public void AddOnReminderContractTracksUpdatesAndFiresChanged()
    {
        AddOnReminder.Clear();
        var notifications = 0;
        void OnChanged() => notifications++;
        AddOnReminder.Changed += OnChanged;
        try
        {
            Assert.False(AddOnReminder.HasUpdate);
            Assert.Null(AddOnReminder.TargetVersion);
            Assert.Null(AddOnReminder.Summary);

            AddOnReminder.Update("0.9.70", "0.9.91", "New features");
            Assert.True(AddOnReminder.HasUpdate);
            Assert.Equal("0.9.91", AddOnReminder.TargetVersion);
            Assert.Equal("New features", AddOnReminder.Summary);
            Assert.Equal(1, notifications);

            // Idempotent update does not re-fire
            AddOnReminder.Update("0.9.70", "0.9.91", "New features");
            Assert.Equal(1, notifications);

            // Current version clears reminder
            AddOnReminder.Update("0.9.91", "0.9.91");
            Assert.False(AddOnReminder.HasUpdate);
            Assert.Null(AddOnReminder.TargetVersion);
            Assert.Null(AddOnReminder.Summary);
            Assert.Equal(2, notifications);

            Assert.Equal("Gym", AddOnReminder.Names(["Gym"]));
            Assert.Equal("Gym and Ivy", AddOnReminder.Names(["Gym", "Ivy"]));
            Assert.Equal("Gym, Ivy and 3 more", AddOnReminder.Names(["Gym", "Ivy", "A", "B", "C"]));
        }
        finally
        {
            AddOnReminder.Changed -= OnChanged;
            AddOnReminder.Clear();
        }
    }

    // ---------------------------------------------------------------- PluginListCache (6-hour disk cache)

    [Fact]
    public void PluginListCachePersistsExpiresIsolatesAndTrimsMemory()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hq-plc-" + Guid.NewGuid().ToString("N"));
        var clock = new DateTimeOffset(2026, 11, 28, 12, 0, 0, TimeSpan.Zero);
        try
        {
            var cache = new PluginListCache(dir, () => clock);
            var list = new List<PluginInfo>
            {
                new("web-clipper", "catalog:web-clipper", "1.2.0", "", "catalog", true, false, [], false, null, null, []),
            };
            cache.Store(list, "https://a.example\nalice", "default");
            Assert.True(File.Exists(cache.FilePath("https://a.example\nalice")));

            var hit = cache.GetEntry("https://a.example\nalice", "default");
            Assert.NotNull(hit);
            Assert.Single(hit!.Plugins);
            Assert.Equal("web-clipper", hit.Plugins[0].Name);

            // Account isolation
            Assert.Null(cache.GetEntry("https://b.example\nbob", "default"));

            // TrimMemory drops RAM cache, reloads cleanly from disk
            cache.TrimMemory();
            Assert.NotNull(cache.GetEntry("https://a.example\nalice", "default"));

            // Clock skew behind stored timestamp counts as stale
            var behind = new PluginListCache(dir, () => clock.AddSeconds(-1));
            Assert.Null(behind.GetEntry("https://a.example\nalice", "default"));

            // Still valid at 5h59m, stale at 6h
            clock = clock.AddHours(6).AddSeconds(-1);
            Assert.NotNull(cache.GetEntry("https://a.example\nalice", "default"));
            clock = clock.AddSeconds(1);
            Assert.Null(cache.GetEntry("https://a.example\nalice", "default"));

            // Forget removes profile entry
            cache.Store(list, "https://a.example\nalice", "default");
            cache.Forget("https://a.example\nalice", "default");
            Assert.Null(cache.GetEntry("https://a.example\nalice", "default"));
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
        }
    }

    // ---------------------------------------------------------------- Serialized CapabilitiesApi.PluginsAsync

    [Fact]
    public async Task PluginsAsyncCoalescesSameProfileAndSerializesDistinctProfiles()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hq-flight-" + Guid.NewGuid().ToString("N"));
        PluginUpdateReminder.ResetForTests();
        try
        {
            var cache = new PluginListCache(dir);
            var (session, rpc, api) = CreateApi(cache: cache);
            await using var ownedRpc = rpc;
            using var ownedSession = session;

            var active = 0;
            var maxConcurrent = 0;
            var callsByProfile = new Dictionary<string, int>(StringComparer.Ordinal);
            var defaultStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var releaseDefault = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

            api.RpcOverride = async (method, p, _, ct) =>
            {
                Assert.Equal("plugins.manage", method);
                var profile = p.Text("profile")!;
                var cur = Interlocked.Increment(ref active);
                maxConcurrent = Math.Max(maxConcurrent, cur);
                lock (callsByProfile) callsByProfile[profile] = callsByProfile.GetValueOrDefault(profile) + 1;
                try
                {
                    if (profile == "default")
                    {
                        defaultStarted.TrySetResult();
                        await releaseDefault.Task.WaitAsync(ct);
                    }
                    else
                    {
                        await Task.Delay(15, ct);
                    }
                    return N("""{"plugins":[{"name":"web-clipper","version":"1.0.0","status":"enabled","update_available":true,"catalog_version":"1.1.0"}]}""");
                }
                finally
                {
                    Interlocked.Decrement(ref active);
                }
            };

            // Two concurrent same-profile callers join ONE flight; two other profiles queue serially behind it.
            var same1 = api.PluginsAsync("default");
            await defaultStarted.Task;
            var same2 = api.PluginsAsync("default");
            var ivy = api.PluginsAsync("ivy");
            var gym = api.PluginsAsync("gym");

            // While default is blocked, ivy and gym must not have started yet.
            Assert.Equal(1, active);
            Assert.False(callsByProfile.ContainsKey("ivy"));
            Assert.False(callsByProfile.ContainsKey("gym"));

            releaseDefault.TrySetResult();
            var results = await Task.WhenAll(same1, same2, ivy, gym);

            Assert.Equal(1, maxConcurrent);
            Assert.Equal(1, callsByProfile["default"]);
            Assert.Equal(1, callsByProfile["ivy"]);
            Assert.Equal(1, callsByProfile["gym"]);
            Assert.All(results, r => Assert.Single(r));
            Assert.Equal(1, PluginUpdateReminder.AvailableCount);
            Assert.Equal("1 Update", PluginUpdateReminder.BadgeLabel);
        }
        finally
        {
            PluginUpdateReminder.ResetForTests();
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
        }
    }

    [Fact]
    public async Task PluginsAsyncTracksTimeoutBackoffAndGenerationInvalidation()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hq-gen-" + Guid.NewGuid().ToString("N"));
        var clock = new DateTimeOffset(2026, 11, 28, 12, 0, 0, TimeSpan.Zero);
        PluginUpdateReminder.ResetForTests(now: () => clock);
        try
        {
            var cache = new PluginListCache(dir, () => clock);
            var (session, rpc, api) = CreateApi(cache: cache, now: () => clock);
            await using var _ = rpc;
            using var __ = session;

            // 1. Timeout records 15-minute backoff
            api.RpcOverride = (_, _, _, _) => throw new GatewayException("timeout", "timed out");
            await Assert.ThrowsAsync<GatewayException>(() => api.PluginsAsync("default"));
            Assert.True(api.PluginListTimedOutRecently());
            clock = clock.AddMinutes(14);
            Assert.True(api.PluginListTimedOutRecently());
            clock = clock.AddMinutes(2);
            Assert.False(api.PluginListTimedOutRecently());

            // 2. Generation invalidation during an in-flight read prevents stale cache write
            var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            api.RpcOverride = async (_, p, _, ct) =>
            {
                if (p.Text("action") == "list")
                {
                    started.TrySetResult();
                    await release.Task.WaitAsync(ct);
                    return N("""{"plugins":[{"name":"stale-plugin","version":"1.0.0","status":"enabled","update_available":true}]}""");
                }
                return N("""{"ok":true}""");
            };

            var listTask = api.PluginsAsync("default");
            await started.Task;
            // Mutation invalidates the in-flight list's generation
            await api.PluginAsync(new PluginAction.Toggle("git:stale-plugin", false), "default");
            release.TrySetResult();
            await listTask;

            // Because generation bumped while the list was in flight, cache and reminder were NOT overwritten with stale data.
            Assert.Null(cache.GetEntry(session.Account.Key, "default"));
            Assert.Equal(0, PluginUpdateReminder.AvailableCount);
        }
        finally
        {
            PluginUpdateReminder.ResetForTests();
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
        }
    }

    // ---------------------------------------------------------------- PluginUpdateReminder opt-out & sweeps

    [Fact]
    public async Task PluginUpdateReminderHonorsOptOutAndStopsEarlyOnTimeout()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hq-rem-" + Guid.NewGuid().ToString("N"));
        var clock = new DateTimeOffset(2026, 11, 28, 12, 0, 0, TimeSpan.Zero);
        var store = new MemoryStore();
        PluginUpdateReminder.ResetForTests(store, () => clock);
        try
        {
            Assert.Equal("plugins.updateCheck.autoOff", PluginUpdateReminder.AutoCheckOffKey);
            Assert.True(PluginUpdateReminder.IsAutomatic);
            Assert.Contains("Turn off on slow gateways", PluginUpdateReminder.AutoCheckFooter);

            var cache = new PluginListCache(dir, () => clock);
            var (session, rpc, api) = CreateApi(cache: cache, now: () => clock);
            await using var _ = rpc;
            using var __ = session;

            var queried = new List<string>();
            api.RpcOverride = (_, p, _, _) =>
            {
                var profile = p.Text("profile")!;
                queried.Add(profile);
                if (profile == "ivy") throw new GatewayException("timeout", "slow");
                return Task.FromResult(N("""{"plugins":[{"name":"web-clipper","version":"1.0.0","status":"enabled","update_available":true,"catalog_version":"1.2.0"},{"name":"hermes-hq-push","version":"0.9.80","status":"enabled","update_available":true,"catalog_version":"0.9.91"}]}"""));
            };

            // Opt-out blocks automatic sweep
            PluginUpdateReminder.IsAutomatic = false;
            Assert.False(PluginUpdateReminder.IsAutomatic);
            Assert.Equal(0, await PluginUpdateReminder.CheckStaleAsync(api, session.Account.Key, ["default", "ivy", "gym"], automatic: true));
            Assert.Empty(queried);

            // Re-enable automatic sweep: queries default (ok), hits timeout on ivy, stops BEFORE gym
            PluginUpdateReminder.IsAutomatic = true;
            var count = await PluginUpdateReminder.CheckStaleAsync(api, session.Account.Key, ["default", "ivy", "gym"], automatic: true);
            Assert.Equal(2, count);
            Assert.Equal(["default", "ivy"], queried);

            // Own add-ons (hermes-hq-push) excluded; only third-party web-clipper counts
            Assert.Equal(1, PluginUpdateReminder.AvailableCount);
            Assert.Equal("1 Update", PluginUpdateReminder.BadgeLabel);

            // Subsequent automatic sweep skips due to recent timeout backoff
            Assert.Equal(0, await PluginUpdateReminder.CheckStaleAsync(api, session.Account.Key, ["default", "ivy", "gym"], automatic: true));

            // Computer-only note suppresses badge until a newer version comes out
            PluginUpdateReminder.NoteNeedsComputer(session.Account.Key, "web-clipper", "1.2.0");
            Assert.Equal(0, PluginUpdateReminder.AvailableCount);
            Assert.Null(PluginUpdateReminder.BadgeLabel);
        }
        finally
        {
            PluginUpdateReminder.ResetForTests();
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
        }
    }

    // ---------------------------------------------------------------- PluginUpdateConsent & Words

    [Fact]
    public async Task PluginUpdateConsentAndWordsMatchContract()
    {
        var statusObj = N("""{"pluginUpdates":true,"pluginUpdatesChecked":true}""") as JsonObject;
        Assert.True(PluginUpdateConsent.Offered(statusObj));
        Assert.True(PluginUpdateConsent.Checked(statusObj));
        Assert.False(PluginUpdateConsent.Offered(null));

        var approved = new PluginUpdateConsent.Approved(
            packages: "tzdata>=2024.1; platform_system == 'Windows', phone-harness",
            findings: [new PluginScanFinding("medium", "subprocess", "run.py", 42)],
            capabilities: ["adds tool foo"]);
        var body = approved.ToBody("ivy", "homeassistant");
        Assert.Equal("ivy", body.Text("profile"));
        Assert.Equal("homeassistant", body.Text("name"));
        Assert.True(body.Bool("accept_capabilities"));
        Assert.True(body.Bool("force"));
        Assert.Equal("tzdata>=2024.1; platform_system == 'Windows', phone-harness", body.Text("packages"));
        Assert.Single(body.Arr("findings")!);
        Assert.Single(body.Arr("capabilities")!);

        Assert.IsType<PluginUpdateCopyResult.Done>(PluginUpdateConsent.ParseJobResult(N("""{"state":"done","unchanged":true}""") as JsonObject));
        Assert.IsType<PluginUpdateCopyResult.DoneNeedsRestart>(PluginUpdateConsent.ParseJobResult(N("""{"state":"done","unchanged":false}""") as JsonObject));
        var computer = Assert.IsType<PluginUpdateCopyResult.Computer>(
            PluginUpdateConsent.ParseJobResult(N("""{"state":"failed","held":{"kind":"packages","changed":false,"now":"tzdata"}}""") as JsonObject));
        Assert.Equal("tzdata", computer.Packages);
        var changed = Assert.IsType<PluginUpdateCopyResult.Failed>(
            PluginUpdateConsent.ParseJobResult(N("""{"state":"failed","held":{"kind":"packages","changed":true,"now":"tzdata"}}""") as JsonObject));
        Assert.Equal(PluginUpdateWords.ChangedSince, changed.Reason);
        Assert.Null(PluginUpdateConsent.ParseJobResult(N("""{"state":"running"}""") as JsonObject));

        const string refusal = "plugin declares new Python dependencies (tzdata; platform_system == 'Windows', phone-harness>=1.0); run hermes plugins update";
        Assert.True(PluginUpdateWords.IsForComputer(refusal));
        var pkgs = PluginUpdateWords.PackagesIn(refusal);
        Assert.Equal(["tzdata", "phone-harness"], PluginUpdateWords.PackageNames([pkgs]));
        Assert.Contains("tzdata and phone-harness", PluginUpdateWords.NeedsBot(["homeassistant"], [pkgs], "Hermes"));
        Assert.Contains("PC", PluginUpdateWords.BotUpdatePrompt([("homeassistant", pkgs, ["default"])]));

        // Live HTTP ApplyAsync POST + GET polling
        var polls = 0;
        var (session, rpc, _) = CreateApi(http: req =>
        {
            if (req.Method == HttpMethod.Post && req.RequestUri!.AbsolutePath == PluginUpdateConsent.Route)
                return JsonResponse(HttpStatusCode.OK, """{"job":"job-42"}""");
            if (req.Method == HttpMethod.Get && req.RequestUri!.AbsolutePath == PluginUpdateConsent.Route + "/job-42")
            {
                polls++;
                return polls == 1
                    ? JsonResponse(HttpStatusCode.OK, """{"state":"running"}""")
                    : JsonResponse(HttpStatusCode.OK, """{"state":"done","unchanged":false}""");
            }
            return JsonResponse(HttpStatusCode.NotFound, "{}");
        });
        await using var ownedRpc = rpc;
        using var ownedSession = session;

        var outcome = await PluginUpdateConsent.ApplyAsync(session, "default", "homeassistant", approved, pollInterval: TimeSpan.FromMilliseconds(1), maxLooks: 10);
        Assert.IsType<PluginUpdateCopyResult.DoneNeedsRestart>(outcome);
        Assert.Equal(2, polls);
    }

    // ---------------------------------------------------------------- RevealEnvAsync & AddOnToolLevelsAsync

    [Fact]
    public async Task CapabilitiesApiRevealsEnvReadsToolLevelsAndSavesPolicies()
    {
        var configBody = """{"mcp_servers":{"github":{"url":"https://mcp.github.example/mcp"}}}""";
        var (session, rpc, api) = CreateApi(http: req =>
        {
            var path = req.RequestUri!.AbsolutePath;
            if (req.Method == HttpMethod.Post && path == "/api/env/reveal")
            {
                var q = req.RequestUri.Query;
                if (q.Contains("profile=missing")) return JsonResponse(HttpStatusCode.NotFound, "{}");
                return JsonResponse(HttpStatusCode.OK, """{"value":"secret-123"}""");
            }
            if (req.Method == HttpMethod.Get && path == PushPolicy.PluginRoute + "/status")
                return JsonResponse(HttpStatusCode.OK, """{"toolPermissions":true,"toolPermissionsAsk":false}""");
            if (req.Method == HttpMethod.Get && path == "/api/config")
                return JsonResponse(HttpStatusCode.OK, configBody);
            return JsonResponse(HttpStatusCode.NotFound, "{}");
        });
        await using var _ = rpc;
        using var __ = session;

        Assert.Equal("secret-123", await api.RevealEnvAsync("OPENAI_API_KEY", "default"));
        Assert.Equal("secret-123", await api.RevealEnvAsync("OPENAI_API_KEY"));
        Assert.Null(await api.RevealEnvAsync("OPENAI_API_KEY", "missing"));

        var (enforced, asks) = await api.AddOnToolLevelsAsync();
        Assert.True(enforced);
        Assert.False(asks);

        JsonNode? addedConfig = null;
        api.RpcOverride = (method, p, _, _) =>
        {
            if (method == "mcp.servers.add") addedConfig = p.Get("config")?.DeepClone();
            return Task.FromResult<JsonNode>(new JsonObject { ["ok"] = true });
        };

        var save = await api.SaveToolPoliciesAsync(
            "github",
            new Dictionary<string, McpToolPermission>
            {
                ["list_issues"] = McpToolPermission.AlwaysAllow,
                ["create_issue"] = McpToolPermission.AutoReview,
                ["delete_repo"] = McpToolPermission.Blocked,
            },
            ["list_issues", "create_issue", "delete_repo"],
            "default");
        Assert.IsType<ToolRulesOutcome.Saved>(save);
        Assert.NotNull(addedConfig);
        Assert.Equal("auto_review", addedConfig!["tools"]!["permissions"]!["create_issue"]!.GetValue<string>());
        Assert.Equal("""["delete_repo"]""", addedConfig["tools"]!["exclude"]!.ToJsonString());
    }

    // ---------------------------------------------------------------- Connector Tool Levels (McpToolPermission)

    [Fact]
    public void McpToolPermissionsReadWritePreserveUnblockedAndSummarizeDrafts()
    {
        var server = N("""
            {
                "url": "https://mcp.example/mcp",
                "tools": {
                    "exclude": ["drop_table"],
                    "permissions": {
                        "drop_table": "needs_approval",
                        "create_pr": "auto_review",
                        "undiscovered_tool": "needs_approval",
                        "junk_tool": 42,
                        "blocked_literal": "blocked"
                    }
                }
            }
            """);

        // Blocked tool still remembers its stored asking level when queried via StoredLevel
        Assert.Equal(McpToolPermission.NeedsApproval, McpToolFilter.StoredLevel(server, "drop_table"));
        Assert.Equal(McpToolPermission.Blocked, McpToolFilter.PermissionFor(server, "drop_table"));
        Assert.Equal(McpToolPermission.AutoReview, McpToolFilter.PermissionFor(server, "create_pr"));
        Assert.Equal(McpToolPermission.AlwaysAllow, McpToolFilter.PermissionFor(server, "read_file"));
        Assert.Equal(McpToolPermission.AlwaysAllow, McpToolFilter.StoredLevel(server, "blocked_literal"));

        // Blocking create_pr preserves its stored auto_review; unblocking drop_table restores needs_approval; junk cleaned; undiscovered preserved
        var next = McpToolFilter.SetPermissions(
            server,
            new Dictionary<string, McpToolPermission>
            {
                ["drop_table"] = McpToolPermission.NeedsApproval,
                ["create_pr"] = McpToolPermission.Blocked,
                ["read_file"] = McpToolPermission.AlwaysAllow,
            },
            ["drop_table", "create_pr", "read_file"]);

        Assert.Equal("""["create_pr"]""", next["tools"]!["exclude"]!.ToJsonString());
        var perms = next["tools"]!["permissions"]!.AsObject();
        Assert.Equal("needs_approval", perms["drop_table"]!.GetValue<string>());
        Assert.Equal("auto_review", perms["create_pr"]!.GetValue<string>()); // preserved while blocked!
        Assert.Equal("needs_approval", perms["undiscovered_tool"]!.GetValue<string>()); // preserved undiscovered!
        Assert.False(perms.ContainsKey("read_file")); // always_allow omitted
        Assert.False(perms.ContainsKey("junk_tool")); // malformed cleaned up
        Assert.False(perms.ContainsKey("blocked_literal"));

        // Returning everything to AlwaysAllow cleans out tools.permissions and tools.exclude cleanly
        var clean = McpToolFilter.SetPermissions(
            N("""{"url":"https://mcp.example/mcp","tools":{"exclude":["a"],"permissions":{"a":"needs_approval"}}}"""),
            new Dictionary<string, McpToolPermission> { ["a"] = McpToolPermission.AlwaysAllow },
            ["a"]);
        Assert.Null(clean["tools"]);

        // Include-mode whitelist stays in include mode
        var inc = N("""{"url":"u","tools":{"include":["a","gone"],"permissions":{"a":"auto_review"}}}""");
        var incNext = McpToolFilter.SetPermissions(
            inc,
            new Dictionary<string, McpToolPermission> { ["a"] = McpToolPermission.Blocked, ["b"] = McpToolPermission.NeedsApproval },
            ["a", "b"]);
        Assert.Equal("""["b","gone"]""", incNext["tools"]!["include"]!.ToJsonString());
        Assert.Null(incNext["tools"]!["exclude"]);
        Assert.Equal("auto_review", incNext["tools"]!["permissions"]!["a"]!.GetValue<string>());
        Assert.Equal("needs_approval", incNext["tools"]!["permissions"]!["b"]!.GetValue<string>());

        // DraftSummary wording
        Assert.Equal("2 tools off, 1 back on", McpToolFilter.DraftSummary(levels: false, 3, blockedCount: 2, backOnCount: 1, 0, 0));
        Assert.Equal("1 tool off, none back on", McpToolFilter.DraftSummary(levels: false, 1, blockedCount: 1, backOnCount: 0, 0, 0));
        Assert.Equal("2 changes · 1 asks every time, 1 auto-review, 1 blocked", McpToolFilter.DraftSummary(levels: true, 2, blockedCount: 1, backOnCount: 0, autoReviewCount: 1, needsApprovalCount: 1));
        Assert.Equal("3 changes · 2 ask every time", McpToolFilter.DraftSummary(levels: true, 3, blockedCount: 0, backOnCount: 0, autoReviewCount: 0, needsApprovalCount: 2));
        Assert.Equal("1 change · all run without asking", McpToolFilter.DraftSummary(levels: true, 1, blockedCount: 0, backOnCount: 1, autoReviewCount: 0, needsApprovalCount: 0));
    }
}
