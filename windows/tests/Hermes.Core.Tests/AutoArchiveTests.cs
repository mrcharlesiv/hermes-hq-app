using System.Net;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Net;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// Archiving & Project Folder's Auto-Archive Stale Chats (App/Settings/Config/VaultBillingPages.swift
/// `SessionsSettingsView`, HermesKit/Settings/GatewayConfigStore.swift, GatewaySettingsAPI.swift): the two config keys,
/// the days rules, the sparse autosave over `PUT /api/config {config}`, and a refused save rolled back with Try Again.
public class AutoArchiveTests
{
    /// A local stand-in for the gateway's config routes: records every request, answers from an in-memory record.
    private sealed class ConfigHandler : HttpMessageHandler
    {
        public JsonObject Record = new() { ["model"] = new JsonObject { ["default"] = "m" }, ["sessions"] = new JsonObject() };
        public readonly List<(string Method, string Path, string Body)> Requests = [];
        public Func<HttpResponseMessage?>? NextPut;

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content == null ? "" : await request.Content.ReadAsStringAsync(ct);
            lock (Requests) Requests.Add((request.Method.Method, request.RequestUri!.PathAndQuery, body));
            if (request.RequestUri!.AbsolutePath != "/api/config") return Json(404, new JsonObject { ["detail"] = "Not Found" });
            if (request.Method == HttpMethod.Get) return Json(200, Record.DeepClone());
            if (NextPut?.Invoke() is { } canned) return canned;
            var patch = JsonNode.Parse(body)!["config"]!;
            Record = (JsonObject)ConfigPath.Merge(Record, patch)!;
            return Json(200, new JsonObject { ["ok"] = true });
        }

        public static HttpResponseMessage Json(int status, JsonNode body) =>
            new((HttpStatusCode)status) { Content = new StringContent(body.ToJsonString(), System.Text.Encoding.UTF8, "application/json") };

        public List<JsonNode> Puts()
        {
            lock (Requests) return Requests.Where(r => r.Method == "PUT").Select(r => JsonNode.Parse(r.Body)!).ToList();
        }
    }

    private static (GatewayConfigStore Store, ConfigHandler Gateway) Make(Action<JsonObject>? seed = null)
    {
        var gateway = new ConfigHandler();
        seed?.Invoke(gateway.Record);
        var session = new GatewaySession(GatewayAddress.Validated("http://127.0.0.1:9"), new StoredAccount("http://127.0.0.1:9", "qa"),
            new MemoryTokenStore(), gateway);
        return (new GatewayConfigStore(new GatewayConfigApi(session)) { Debounce = TimeSpan.FromMilliseconds(40) }, gateway);
    }

    private static async Task Until(Func<bool> condition, int ms = 3000)
    {
        var until = DateTime.UtcNow.AddMilliseconds(ms);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(10);
        }
    }

    private static bool Same(JsonNode? a, string json) => JsonNode.DeepEquals(a, JsonNode.Parse(json));

    [Fact]
    public void WordsAreTheMacs()
    {
        Assert.Equal("Auto-Archive Stale Chats", AutoArchive.Title);
        Assert.Equal("Archive After", AutoArchive.DaysLabel);
        Assert.Equal("days", AutoArchive.DaysUnit);
        Assert.Equal("30", AutoArchive.DaysPlaceholder);
        Assert.Equal("Pinned chats are never archived, and nothing is deleted.", AutoArchive.Footer);
        Assert.Equal("Couldn’t Save Your Change", AutoArchive.SaveFailedTitle);
        Assert.Equal("Archiving & Project Folder", SettingsWords.SessionsPageTitle);
    }

    [Fact]
    public void SearchFindsAutoArchiveOnItsPage()
    {
        var hit = SettingsSearch.Results("old chats", SettingsSearch.Index);
        var row = Assert.Single(hit, e => e.Id == "app:auto-archive");
        Assert.Equal("Auto-Archive Stale Chats", row.Label);
        Assert.Equal(SettingsWords.SessionsPageTitle, row.Context);
        Assert.Equal("sessions", row.Target);
        Assert.Contains(SettingsSearch.Results("retention", SettingsSearch.Index), e => e.Id == "app:auto-archive");
    }

    [Fact]
    public async Task ReadsTheRecordOverGetApiConfig()
    {
        var (store, gateway) = Make(r => r["sessions"] = new JsonObject { ["auto_archive"] = true, ["auto_archive_days"] = 14 });
        await store.LoadAsync();
        Assert.Equal(GatewayConfigStore.LoadPhase.Loaded, store.Phase);
        Assert.True(AutoArchive.Enabled(store));
        Assert.Equal(14L, AutoArchive.StoredDays(store));
        Assert.Equal(("GET", "/api/config"), (gateway.Requests[0].Method, gateway.Requests[0].Path));
    }

    [Theory]
    [InlineData(null, 30L)]
    [InlineData("0", 1L)]
    [InlineData("-4", 1L)]
    [InlineData("14.7", 14L)]
    [InlineData("\"21\"", 21L)]
    [InlineData("\"soon\"", 30L)]
    [InlineData("true", 30L)]
    public async Task StoredDaysIsAtLeastOneAndThirtyWhenUnset(string? stored, long shown)
    {
        var (store, _) = Make(r => { if (stored != null) r["sessions"] = new JsonObject { ["auto_archive_days"] = JsonNode.Parse(stored) }; });
        await store.LoadAsync();
        Assert.Equal(shown, AutoArchive.StoredDays(store));
    }

    [Theory]
    [InlineData("\"yes\"")]
    [InlineData("1")]
    [InlineData("null")]
    public async Task OnlyARealTrueTurnsItOn(string stored)
    {
        var (store, _) = Make(r => r["sessions"] = new JsonObject { ["auto_archive"] = JsonNode.Parse(stored) });
        await store.LoadAsync();
        Assert.False(AutoArchive.Enabled(store));
    }

    [Fact]
    public async Task TurningItOnSavesBothKeysAsOneSparsePut()
    {
        var (store, gateway) = Make();
        await store.LoadAsync();
        AutoArchive.Toggle(store, true);
        Assert.True(AutoArchive.Enabled(store)); // shown at once
        await Until(() => gateway.Puts().Count == 1 && store.Saving == 0);
        var put = gateway.Puts()[0];
        Assert.True(Same(put, """{"config":{"sessions":{"auto_archive":true,"auto_archive_days":30}}}"""), put.ToJsonString());
        Assert.Contains(gateway.Requests, r => r is { Method: "PUT", Path: "/api/config" });
        // The gateway kept it, and a fresh read shows it.
        var (again, _) = (new GatewayConfigStore(new GatewayConfigApi(new GatewaySession(GatewayAddress.Validated("http://127.0.0.1:9"),
            new StoredAccount("http://127.0.0.1:9", "qa"), new MemoryTokenStore(), gateway))), 0);
        await again.LoadAsync();
        Assert.True(AutoArchive.Enabled(again));
        Assert.Equal(30L, AutoArchive.StoredDays(again));
    }

    [Fact]
    public async Task TurningItOffSendsOnlyWhatChanged()
    {
        var (store, gateway) = Make(r => r["sessions"] = new JsonObject { ["auto_archive"] = true, ["auto_archive_days"] = 14 });
        await store.LoadAsync();
        AutoArchive.Toggle(store, false);
        await Until(() => gateway.Puts().Count == 1 && store.Saving == 0);
        Assert.True(Same(gateway.Puts()[0], """{"config":{"sessions":{"auto_archive":false}}}"""), gateway.Puts()[0].ToJsonString());
        Assert.Equal(14L, AutoArchive.StoredDays(store));
        Assert.True(Same(gateway.Record["sessions"], """{"auto_archive":false,"auto_archive_days":14}"""));
    }

    [Fact]
    public async Task QuickChangesSaveOnceAfterTheLast()
    {
        var (store, gateway) = Make();
        store.Debounce = TimeSpan.FromMilliseconds(150);
        await store.LoadAsync();
        AutoArchive.Toggle(store, true);
        AutoArchive.Toggle(store, false);
        AutoArchive.Toggle(store, true);
        await Until(() => gateway.Puts().Count == 1 && store.Saving == 0);
        await Task.Delay(300);
        Assert.Single(gateway.Puts());
    }

    [Fact]
    public async Task FlushSendsAtOnce()
    {
        var (store, gateway) = Make();
        store.Debounce = TimeSpan.FromSeconds(30);
        await store.LoadAsync();
        AutoArchive.Toggle(store, true);
        Assert.Empty(gateway.Puts());
        await store.Flush();
        Assert.Single(gateway.Puts());
    }

    [Theory]
    [InlineData("14", "14", 14)]
    [InlineData(" 7 ", " 7 ", 7)]
    [InlineData("+9", "+9", 9)]
    [InlineData("99999999999", "99999999999", 99999999999)]
    public async Task ArchiveAfterSavesAWholeNumberOfOneOrMore(string typed, string shown, long saved)
    {
        var (store, gateway) = Make(r => r["sessions"] = new JsonObject { ["auto_archive"] = true, ["auto_archive_days"] = 30 });
        await store.LoadAsync();
        Assert.Equal(shown, AutoArchive.CommitDays(store, typed));
        await store.Flush();
        var put = Assert.Single(gateway.Puts());
        Assert.True(Same(put, "{\"config\":{\"sessions\":{\"auto_archive_days\":" + saved + "}}}"), put.ToJsonString());
        Assert.Equal(saved, AutoArchive.StoredDays(store));
    }

    [Theory]
    [InlineData("0", "30")]
    [InlineData("-3", "30")]
    [InlineData("abc", "30")]
    [InlineData("1.5", "30")]
    [InlineData("99999999999999999999", "30")]
    [InlineData("30", "30")]
    [InlineData("", "")]
    public async Task ArchiveAfterPutsTheKeptNumberBackForAnythingElse(string typed, string shown)
    {
        var (store, gateway) = Make(r => r["sessions"] = new JsonObject { ["auto_archive"] = true, ["auto_archive_days"] = 30 });
        await store.LoadAsync();
        Assert.Equal(shown, AutoArchive.CommitDays(store, typed));
        await store.Flush();
        await Task.Delay(80);
        Assert.Empty(gateway.Puts());
    }

    [Fact]
    public async Task ArchiveAfterIsNotSavedWhileOff()
    {
        var (store, gateway) = Make(r => r["sessions"] = new JsonObject { ["auto_archive"] = false, ["auto_archive_days"] = 30 });
        await store.LoadAsync();
        Assert.Equal("14", AutoArchive.CommitDays(store, "14"));
        Assert.Equal("30", AutoArchive.CommitDays(store, "x"));
        await store.Flush();
        await Task.Delay(80);
        Assert.Empty(gateway.Puts());
    }

    [Fact]
    public async Task ARefusedSaveRollsBackAndTryAgainSendsTheSameChange()
    {
        var (store, gateway) = Make();
        await store.LoadAsync();
        gateway.NextPut = () => { gateway.NextPut = null; return ConfigHandler.Json(500, new JsonObject { ["detail"] = "disk full" }); };
        AutoArchive.Toggle(store, true);
        await Until(() => store.Failure != null && store.Saving == 0);
        Assert.Equal("disk full", store.Failure!.Text);
        Assert.Equal("HTTP 500", store.Failure.Detail);
        Assert.False(AutoArchive.Enabled(store)); // the saved value is back on the page
        Assert.False(gateway.Record["sessions"]!.AsObject().ContainsKey("auto_archive"));

        await store.Retry();
        Assert.Null(store.Failure);
        Assert.True(AutoArchive.Enabled(store));
        Assert.Equal(2, gateway.Puts().Count);
        Assert.True(Same(gateway.Puts()[1], """{"config":{"sessions":{"auto_archive":true,"auto_archive_days":30}}}"""));
        Assert.True(Same(gateway.Record["sessions"], """{"auto_archive":true,"auto_archive_days":30}"""));
    }

    [Fact]
    public async Task OkFalseIsARefusal()
    {
        var (store, gateway) = Make();
        await store.LoadAsync();
        gateway.NextPut = () => ConfigHandler.Json(200, new JsonObject { ["ok"] = false });
        AutoArchive.Toggle(store, true);
        await Until(() => store.Failure != null && store.Saving == 0);
        Assert.Equal("Your gateway didn’t accept the change.", store.Failure!.Text);
        Assert.False(AutoArchive.Enabled(store));
        store.DismissFailure();
        Assert.Null(store.Failure);
    }

    [Fact]
    public async Task AReadOnlyGatewayNeverSends()
    {
        var gateway = new ConfigHandler();
        var session = new GatewaySession(GatewayAddress.Validated("http://127.0.0.1:9"), new StoredAccount("http://127.0.0.1:9", "qa"), new MemoryTokenStore(), gateway);
        var store = new GatewayConfigStore(new GatewayConfigApi(session), readOnly: true) { Debounce = TimeSpan.FromMilliseconds(20) };
        await store.LoadAsync();
        AutoArchive.Toggle(store, true);
        await Until(() => store.Failure != null);
        Assert.Equal("Changes are turned off for this gateway in this build.", store.Failure!.Text);
        Assert.Empty(gateway.Puts());
        Assert.False(AutoArchive.Enabled(store));
    }

    [Fact]
    public async Task AFailedReadShowsWhyNotAnEmptyPage()
    {
        var failing = new GatewaySession(GatewayAddress.Validated("http://127.0.0.1:9"), new StoredAccount("http://127.0.0.1:9", "qa"),
            new MemoryTokenStore(), new Failing());
        var bad = new GatewayConfigStore(new GatewayConfigApi(failing));
        await bad.LoadAsync();
        Assert.Equal(GatewayConfigStore.LoadPhase.Failed, bad.Phase);
        Assert.Equal("Your gateway couldn’t send this list. Try again in a moment.", bad.LoadError);
        Assert.Null(bad.Config);
        Assert.False(AutoArchive.Enabled(bad));
        AutoArchive.Toggle(bad, true); // nothing to edit before a read
        Assert.Null(bad.Config);
    }

    private sealed class Failing : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(ConfigHandler.Json(500, new JsonObject { ["error"] = "<html>boom</html>" }));
    }

    [Fact]
    public void ConfigPathDiffAndMergeAreSparse()
    {
        var record = JsonNode.Parse("""{"sessions":{"auto_archive":false,"auto_archive_days":30},"model":{"default":"m"}}""");
        var next = ConfigPath.Set(record, "sessions.auto_archive", true);
        Assert.True(Same(ConfigPath.Diff(record, next), """{"sessions":{"auto_archive":true}}"""));
        Assert.True(Same(ConfigPath.Merge(record, JsonNode.Parse("""{"sessions":{"auto_archive_days":7}}""")),
            """{"sessions":{"auto_archive":false,"auto_archive_days":7},"model":{"default":"m"}}"""));
        Assert.Null(ConfigPath.Parts("sessions.__proto__"));
        Assert.Null(ConfigPath.Get(record, "sessions..x"));
    }
}
