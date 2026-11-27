using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Net;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// Settings against scripts/fixtures/settings-gateway.py (windows/ci/fixtures): the gateway card's facts (the roster's
/// count and the Hermes version from /api/status, as About shows it) and Default Project Folder's check against
/// GET /api/fs/list, including a folder that stops existing. Run through windows/scripts/e2e.sh
/// (HQW_E2E_SETTINGS_CREDENTIALS); without it these pass vacuously.
[Trait("Category", "E2E")]
[Collection(SettingsStandIn.Name)]
public class SettingsEndToEndTests
{
    private static async Task Until(Func<Task<bool>> condition, int seconds = 20)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!await condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(100);
        }
    }

    private static async Task Post(string url, string path, object body)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");
        (await http.PostAsync(url.TrimEnd('/') + path, content)).EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task GatewayCardFactsAndDefaultProjectFolder()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_SETTINGS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Post(url, "/__settings/reset", new { });

        var signIn = new SignIn(new MemoryTokenStore());
        var session = await signIn.PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);

        // The card: "Connected · N Bots · Hermes 0.21.5" (the fixture's /api/status says v0.21.5's release).
        var bots = await client.BotsAsync();
        Assert.NotEmpty(bots);
        var status = await session.GetJsonAsync("/api/status", timeout: TimeSpan.FromSeconds(15));
        var version = SettingsWords.Version(status);
        Assert.Equal("0.21.5", version);
        Assert.Equal($"Connected · {bots.Count} {(bots.Count == 1 ? "Bot" : "Bots")} · Hermes 0.21.5",
            SettingsWords.StatusLine(GatewayConnection.Ready, bots.Count, version));

        // Default Project Folder: kept only when it is a folder on the computer running Hermes.
        Assert.True(await DefaultProjectFolder.ExistsAsync(session, "/Users/fixture/Projects/app"));
        Assert.True(await DefaultProjectFolder.ExistsAsync(session, "/fixture/"));
        Assert.False(await DefaultProjectFolder.ExistsAsync(session, "/Users/fixture/Nowhere"));
        await Post(url, "/__settings/fs", new { missing = new[] { "/Users/fixture/Projects/app" } });
        await Until(async () => !await DefaultProjectFolder.ExistsAsync(session, "/Users/fixture/Projects/app"));
        await Post(url, "/__settings/reset", new { });
        await Until(() => DefaultProjectFolder.ExistsAsync(session, "/Users/fixture/Projects/app"));
    }

    /// Archiving & Project Folder's Auto-Archive Stale Chats against the stand-in's `/api/config`: the switch and Archive
    /// After are kept by the gateway (a fresh read shows them), the rest of the record is untouched, and a refused PUT
    /// (`/__settings/fail`) shows the gateway's words, puts the kept value back, and Try Again lands it.
    [Fact]
    public async Task AutoArchiveRoundTripsAndRollsBack()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_SETTINGS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Post(url, "/__settings/reset", new { });
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        GatewayConfigStore Fresh() => new(new GatewayConfigApi(session)) { Debounce = TimeSpan.FromMilliseconds(50) };

        var store = Fresh();
        await store.LoadAsync();
        Assert.Equal(GatewayConfigStore.LoadPhase.Loaded, store.Phase);
        var before = store.Config!.DeepClone();
        var wasOn = AutoArchive.Enabled(store);

        AutoArchive.Toggle(store, !wasOn);
        await store.Flush();
        if (wasOn) { AutoArchive.Toggle(store, true); await store.Flush(); }
        Assert.Null(store.Failure);
        Assert.Equal("14", AutoArchive.CommitDays(store, "14"));
        await store.Flush();
        Assert.Null(store.Failure);

        var read = Fresh();
        await read.LoadAsync();
        Assert.True(AutoArchive.Enabled(read));
        Assert.Equal(14L, AutoArchive.StoredDays(read));
        // Nothing else in the record changed.
        var others = (JsonObject)read.Config!.DeepClone();
        var original = (JsonObject)before.DeepClone();
        others.Remove("sessions"); original.Remove("sessions");
        Assert.True(JsonNode.DeepEquals(original, others));

        // A refused save: the gateway's words, the kept value back, then Try Again.
        await Post(url, "/__settings/fail", new { method = "PUT /api/config", mode = "error", count = 1 });
        AutoArchive.Toggle(store, false);
        await store.Flush();
        Assert.NotNull(store.Failure);
        Assert.Equal("disk full", store.Failure!.Text);
        Assert.True(AutoArchive.Enabled(store));
        var still = Fresh();
        await still.LoadAsync();
        Assert.True(AutoArchive.Enabled(still));

        await store.Retry();
        Assert.Null(store.Failure);
        var after = Fresh();
        await after.LoadAsync();
        Assert.False(AutoArchive.Enabled(after));
        Assert.Equal(14L, AutoArchive.StoredDays(after));
        await Post(url, "/__settings/reset", new { });
    }

    /// The file actions' seam with canned answers: what was asked, saved and shown.
    private sealed class ScriptedUi : ISettingsFileUi
    {
        public readonly List<(string Title, string? Message, string Action)> Confirms = [];
        public readonly List<(string Title, string Reason)> Failures = [];
        public readonly List<(string Title, string Detail)> Huds = [];
        public readonly List<(string Name, byte[] Data)> Saved = [];
        public bool Answer = true;
        public PickedSettingsFile? Picked;
        public Task<bool> ConfirmAsync(string title, string? message, string action) { Confirms.Add((title, message, action)); return Task.FromResult(Answer); }
        public Task<bool> SaveAsync(string fileName, byte[] data) { Saved.Add((fileName, data)); return Task.FromResult(true); }
        public Task<PickedSettingsFile?> PickAsync() => Task.FromResult(Picked);
        public void Fail(string title, string reason) => Failures.Add((title, reason));
        public void Done(string title, string detail) => Huds.Add((title, detail));
    }

    private static async Task<JsonNode> State(string url)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + "/__settings/state"))!;
    }

    private static List<JsonNode> ConfigWrites(JsonNode state) =>
        state["writes"]!.AsArray().Where(w => w!.Str("method") == "PUT /api/config").Select(w => w!["params"]!).ToList();

    /// Export Settings…, Import Settings… and Reset to Defaults… against the stand-in's `/api/config`,
    /// `/api/config/defaults` and `PUT /api/config`: the exported file has none of the record's (fake) credentials, an
    /// edited copy imports as only its changes with the credentials kept on the gateway, a file that isn't settings is
    /// turned away before any call, Reset writes nothing until confirmed and then sends Hermes' defaults whole, and a
    /// refused call shows the Mac's title with the gateway's words.
    [Fact]
    public async Task ExportImportAndResetAgainstTheGateway()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_SETTINGS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Post(url, "/__settings/reset", new { });
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        var store = new GatewayConfigStore(new GatewayConfigApi(session)) { Debounce = TimeSpan.FromMilliseconds(50) };
        var ui = new ScriptedUi();
        var status = new List<string?>();
        var actions = new SettingsFileActions(store, ui) { Now = () => new DateTime(2026, 11, 21, 9, 0, 0, DateTimeKind.Local) };
        actions.StatusChanged += s => status.Add(s);

        // Export: credentials left out (the stand-in's record carries a connector bearer token, a key argument and a
        // provider key, all fake), everything else kept.
        await actions.ExportAsync();
        var (name, data) = Assert.Single(ui.Saved);
        Assert.Equal("Hermes settings 2026-11-21.json", name);
        var text = System.Text.Encoding.UTF8.GetString(data);
        foreach (var secret in new[] { "fixture-bearer-not-real-0000", "fixture-files-key-0000", "sk-fix...0000" })
            Assert.DoesNotContain(secret, text);
        Assert.Contains("«left out of this export»", text);
        var exported = (JsonObject)JsonNode.Parse(data)!;
        Assert.Equal("America/New_York", exported["timezone"]!.GetValue<string>());
        Assert.Empty(ConfigWrites(await State(url)));

        // Import: the exported file with two settings changed → asked with the count → only those two sent.
        exported["timezone"] = "UTC";
        exported["agent"]!["max_turns"] = 77;
        ui.Picked = new PickedSettingsFile(System.Text.Encoding.UTF8.GetBytes(exported.ToJsonString()));
        await actions.PickImportAsync();
        Assert.Equal([(SettingsImportWords.ConfirmTitle, SettingsImportWords.ConfirmMessage(2), "Import")], ui.Confirms);
        var write = Assert.Single(ConfigWrites(await State(url)));
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse("{\"profile\":\"default\",\"config\":{\"timezone\":\"UTC\",\"agent\":{\"max_turns\":77}}}"), write),
            write.ToJsonString());
        Assert.Equal("Settings imported. 2 settings changed.", status.Last());
        Assert.Equal([("Settings Imported", "2 settings changed.")], ui.Huds);
        var kept = (await State(url))["config"]!;
        Assert.Equal("Bearer fixture-bearer-not-real-0000", kept["mcp_servers"]!["github"]!["headers"]!["Authorization"]!.GetValue<string>());
        Assert.Equal(77, kept["agent"]!["max_turns"]!.GetValue<int>());
        Assert.Equal(77, store.Value("agent.max_turns")!.GetValue<int>());

        // Not a settings file: the Mac's words, and no call at all.
        var before = (await State(url))["rest"]!.AsArray().Count;
        ui.Picked = new PickedSettingsFile(System.Text.Encoding.UTF8.GetBytes("[\"not\", \"settings\"]"));
        await actions.PickImportAsync();
        Assert.Equal(("Couldn’t Import Settings", "That file isn’t a Hermes settings file."), ui.Failures.Last());
        Assert.Equal(before, (await State(url))["rest"]!.AsArray().Count);

        // Reset: Cancel writes nothing; Reset to Defaults reads Hermes' defaults and sends them whole.
        ui.Answer = false;
        await actions.ConfirmResetAsync();
        Assert.Equal(("Reset All Settings to Defaults?",
            "Every setting on the computer running Hermes goes back to its Hermes default. Keys, bots and chats stay. Export Settings… first to keep a copy.",
            "Reset to Defaults"), ui.Confirms.Last());
        Assert.Single(ConfigWrites(await State(url)));
        ui.Answer = true;
        await actions.ConfirmResetAsync();
        var state = await State(url);
        var rest = state["rest"]!.AsArray().Select(r => $"{r!.Str("method")} {r!.Str("path")}").ToList();
        Assert.Contains("GET /api/config/defaults", rest);
        Assert.True(rest.LastIndexOf("GET /api/config/defaults") < rest.LastIndexOf("PUT /api/config"));
        var reset = ConfigWrites(state).Last();
        Assert.True(JsonNode.DeepEquals(await session.GetJsonAsync("/api/config/defaults"), reset["config"]), reset.ToJsonString());
        Assert.Equal(90, state["config"]!["agent"]!["max_turns"]!.GetValue<int>());
        Assert.Equal("", state["config"]!["timezone"]!.GetValue<string>());
        Assert.Equal("Settings reset to Hermes defaults.", status.Last());

        // A refused call: the Mac's title and the gateway's words.
        await Post(url, "/__settings/fail", new { method = "GET /api/config/defaults", mode = "error", count = 1 });
        await actions.ConfirmResetAsync();
        Assert.Equal(("Couldn’t Reset Settings", "disk full"), ui.Failures.Last());
        await Post(url, "/__settings/fail", new { method = "GET /api/config", mode = "error", count = 1 });
        await actions.ExportAsync();
        Assert.Equal(("Couldn’t Export Settings", "disk full"), ui.Failures.Last());
        await Post(url, "/__settings/fail", new { method = "PUT /api/config", mode = "error", count = 1 });
        ui.Picked = new PickedSettingsFile(System.Text.Encoding.UTF8.GetBytes("{\"timezone\":\"Europe/Paris\"}"));
        await actions.PickImportAsync();
        Assert.Equal(("Couldn’t Import Settings", "disk full"), ui.Failures.Last());
        Assert.Equal("", (await State(url))["config"]!["timezone"]!.GetValue<string>());
        await Post(url, "/__settings/reset", new { });
    }
}
