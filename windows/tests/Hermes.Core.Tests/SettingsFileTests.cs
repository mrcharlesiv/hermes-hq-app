using System.Net;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Net;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// Settings' Export Settings…, Import Settings… and Reset to Defaults… (App/Settings/SettingsNavigator.swift
/// `SettingsFileActions`, HermesKit/Settings/SettingsFile.swift, SettingsImportWords.swift, GatewaySettingsAPI.swift,
/// GatewayConfigStore.swift `write` / `fresh`). The golden files in SettingsFileGolden/ were written by the Swift
/// reference's own SettingsFile and ConfigPath compiled on a Mac (golden.swift.txt is the program; all values invented).
public class SettingsFileTests
{
    private static string Golden(string name, [CallerFilePath] string here = "") =>
        File.ReadAllText(Path.Combine(Path.GetDirectoryName(here)!, "SettingsFileGolden", name));

    // ------------------------------------------------------------------ a local stand-in for the config routes

    private sealed class ConfigHandler : HttpMessageHandler
    {
        public JsonObject Record = new();
        public JsonObject Defaults = new() { ["agent"] = new JsonObject { ["max_turns"] = 90 }, ["toolsets"] = new JsonArray("hermes-cli") };
        public readonly List<(string Method, string Path, string Body)> Requests = [];
        /// "GET /api/config", "GET /api/config/defaults", "PUT /api/config" → a canned answer once.
        public readonly Dictionary<string, Func<HttpResponseMessage>> Fail = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content == null ? "" : await request.Content.ReadAsStringAsync(ct);
            var path = request.RequestUri!.AbsolutePath;
            lock (Requests) Requests.Add((request.Method.Method, request.RequestUri!.PathAndQuery, body));
            var key = $"{request.Method.Method} {path}";
            if (Fail.Remove(key, out var canned)) return canned();
            if (key == "GET /api/config") return Json(200, Record.DeepClone());
            if (key == "GET /api/config/defaults") return Json(200, Defaults.DeepClone());
            if (key == "PUT /api/config")
            {
                Record = (JsonObject)ConfigPath.Merge(Record, JsonNode.Parse(body)!["config"])!;
                return Json(200, new JsonObject { ["ok"] = true });
            }
            return Json(404, new JsonObject { ["detail"] = "Not Found" });
        }

        public static HttpResponseMessage Json(int status, JsonNode body) =>
            new((HttpStatusCode)status) { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };

        public List<(string Method, string Path, string Body)> Calls() { lock (Requests) return [.. Requests]; }
        public List<JsonNode> Puts() => Calls().Where(r => r.Method == "PUT").Select(r => JsonNode.Parse(r.Body)!).ToList();
    }

    /// The seam the app fills with ContentDialogs and the Windows file pickers.
    private sealed class FakeUi : ISettingsFileUi
    {
        public readonly List<string> Log = [];
        public readonly List<(string Title, string? Message, string Action)> Confirms = [];
        public readonly List<(string Title, string Reason)> Failures = [];
        public readonly List<(string Title, string Detail)> Huds = [];
        public readonly List<(string Name, byte[] Data)> Saved = [];
        public bool Answer = true;
        public bool SaveChosen = true;
        public PickedSettingsFile? Picked;

        public Task<bool> ConfirmAsync(string title, string? message, string action)
        {
            Confirms.Add((title, message, action)); Log.Add($"confirm {title}");
            return Task.FromResult(Answer);
        }
        public Task<bool> SaveAsync(string fileName, byte[] data)
        {
            Log.Add($"save {fileName}");
            if (SaveChosen) Saved.Add((fileName, data));
            return Task.FromResult(SaveChosen);
        }
        public Task<PickedSettingsFile?> PickAsync() { Log.Add("pick"); return Task.FromResult(Picked); }
        public void Fail(string title, string reason) { Failures.Add((title, reason)); Log.Add($"fail {title}"); }
        public void Done(string title, string detail) { Huds.Add((title, detail)); Log.Add($"hud {title}"); }
    }

    private static (SettingsFileActions Actions, GatewayConfigStore Store, ConfigHandler Gateway, FakeUi Ui, List<string?> Status) Make(JsonObject? record = null)
    {
        var gateway = new ConfigHandler();
        if (record != null) gateway.Record = record;
        var session = new GatewaySession(GatewayAddress.Validated("http://127.0.0.1:9"), new StoredAccount("http://127.0.0.1:9", "qa"),
            new MemoryTokenStore(), gateway);
        var store = new GatewayConfigStore(new GatewayConfigApi(session)) { Debounce = TimeSpan.FromMilliseconds(30) };
        var ui = new FakeUi();
        var status = new List<string?>();
        var actions = new SettingsFileActions(store, ui) { Now = () => new DateTime(2026, 11, 21, 23, 30, 0, DateTimeKind.Local) };
        actions.StatusChanged += s => { lock (status) status.Add(s); };
        return (actions, store, gateway, ui, status);
    }

    private static JsonObject Obj(string json) => (JsonObject)JsonNode.Parse(json)!;

    // ------------------------------------------------------------------ the file (HermesKit SettingsFile)

    [Fact]
    public void ExportFileIsByteForByteWhatSwiftWrites()
    {
        var config = JsonNode.Parse(Golden("config.json"));
        var bytes = SettingsFile.FileData(config);
        Assert.Equal(Golden("export.json"), Encoding.UTF8.GetString(bytes));
        // No BOM, UTF-8, and every credential in the record is gone.
        Assert.NotEqual(0xEF, bytes[0]);
        var text = Encoding.UTF8.GetString(bytes);
        foreach (var secret in new[] { "plain-secret-value", "pw123", "abc123", "sk-abcdefghijklmnop", "eyJhbGciOi", "ghp_abcdefghijklmn",
                     "fixture-bearer-not-real-0000", "fixture-files-key-0000", "value-1", "secret-in-list", "zzz", "sk-fix...0000" })
            Assert.DoesNotContain(secret, text);
    }

    /// URLs (user info, credential parameters, percent escapes, ${VAR}s), key shapes, header and assignment arguments,
    /// flags before a credential, random-looking runs and connector env/headers maps, as Swift redacts them.
    [Fact]
    public void UrlsAndConnectorArgumentsAreRedactedAsSwiftDoes()
    {
        var bytes = SettingsFile.FileData(JsonNode.Parse(Golden("urls-in.json")));
        Assert.Equal(Golden("urls-out.json"), Encoding.UTF8.GetString(bytes));
    }

    [Theory]
    [InlineData(1e15 + 0.5, "1000000000000000.5")]
    [InlineData(4503599627370495.5, "4503599627370495.5")]
    [InlineData(1e16, "1e+16")]
    [InlineData(123456789012.25, "123456789012.25")]
    [InlineData(5e-324, "5e-324")]
    [InlineData(9.5e15, "9.5e+15")]
    [InlineData(1e-5, "1e-05")]
    [InlineData(0.0001, "0.0001")]
    [InlineData(-0.0, "0")]
    [InlineData(120.0, "120")]
    public void NumbersAreWrittenAsSwiftWritesThem(double value, string expected) => Assert.Equal(expected, SettingsFile.Number(value));

    [Fact]
    public void CredentialKeysMatchSwift()
    {
        foreach (var k in new[] { "api_key", "API-KEY", "apikey", "token", "auth_token", "client_secret", "password", "Authorization", "bearer", "cookie_jar" })
            Assert.True(SettingsFile.SecretKey(k), k);
        foreach (var k in new[] { "api_key_env", "token_env_var", "password_store", "secret_backend", "model", "keyboard", "credential_file" })
            Assert.False(SettingsFile.SecretKey(k), k);
        foreach (var k in new[] { "key", "DEMO_KEY", "passwd", "credential_file", "x-token", "cookie" })
            Assert.True(SettingsFile.ConnectorSecretKey(k), k);
        foreach (var k in new[] { "key_env", "command", "url", "timeout" })
            Assert.False(SettingsFile.ConnectorSecretKey(k), k);
    }

    [Fact]
    public void FileNameIsProfileAndLocalDay()
    {
        var day = new DateTime(2026, 11, 22, 0, 5, 0, DateTimeKind.Local);
        Assert.Equal("Hermes settings 2026-11-22.json", SettingsFile.ExportFileName("Hermes", day));
        Assert.Equal("My Bot Name settings 2026-11-22.json", SettingsFile.ExportFileName("  My:Bot/Name? ", day));
        Assert.Equal("Hermes settings 2026-11-22.json", SettingsFile.ExportFileName("", day));
        Assert.Equal("a b c settings 2026-11-22.json", SettingsFile.ExportFileName("a\u0001b|c", day));
    }

    [Fact]
    public void EmptyContainersAndNumbersAreWrittenAsSwiftWritesThem()
    {
        Assert.Equal("{\n\n}", Encoding.UTF8.GetString(SettingsFile.FileData(new JsonObject())));
        Assert.Equal("{\n  \"a\" : [\n\n  ],\n  \"b\" : {\n\n  },\n  \"f\" : 0.1,\n  \"n\" : 1e+20\n}",
            Encoding.UTF8.GetString(SettingsFile.FileData(Obj("{\"n\":1e20,\"f\":0.1,\"b\":{},\"a\":[]}"))));
        Assert.Equal("{\n  \"B\" : 3,\n  \"Z\" : 6,\n  \"_x\" : 5,\n  \"a\" : 4,\n  \"a10\" : 1,\n  \"a2\" : 2,\n  \"e\" : 8,\n  \"é\" : 7\n}",
            Encoding.UTF8.GetString(SettingsFile.FileData(Obj("{\"a10\":1,\"a2\":2,\"B\":3,\"a\":4,\"_x\":5,\"Z\":6,\"é\":7,\"e\":8}"))));
        Assert.Equal("{\n  \"s\" : \"tab\\there \\\"q\\\" \\\\ \\u0001 </ok>\"\n}",
            Encoding.UTF8.GetString(SettingsFile.FileData(Obj("{\"s\":\"tab\\there \\\"q\\\" \\\\ \\u0001 </ok>\"}"))));
    }

    [Fact]
    public void PlaceholdersAreKnown()
    {
        Assert.True(SettingsFile.IsPlaceholder(JsonValue.Create("«left out of this export»")));
        Assert.True(SettingsFile.IsPlaceholder(JsonValue.Create("«redacted»")));
        Assert.True(SettingsFile.IsPlaceholder(JsonValue.Create("***")));
        Assert.True(SettingsFile.IsPlaceholder(JsonValue.Create(" **** ")));
        Assert.False(SettingsFile.IsPlaceholder(JsonValue.Create("**")));
        Assert.False(SettingsFile.IsPlaceholder(JsonValue.Create("abc")));
        Assert.False(SettingsFile.IsPlaceholder(JsonValue.Create(3)));
    }

    [Fact]
    public void ImportPatchIsWhatSwiftSends()
    {
        var current = JsonNode.Parse(Golden("config.json"));
        var file = JsonNode.Parse(Golden("import-file.json"));
        var patch = SettingsFile.ImportPatch(file, current);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(Golden("import-patch.json")), patch), patch.ToJsonString());
        Assert.Equal(3, SettingsImportWords.ChangeCount(patch));
    }

    [Fact]
    public void ImportWordsAndToolsetsGuard()
    {
        Assert.Equal("Import Settings?", SettingsImportWords.ConfirmTitle);
        Assert.Equal("Import", SettingsImportWords.ConfirmAction);
        Assert.Equal("Settings Imported", SettingsImportWords.DoneTitle);
        Assert.Equal("3 settings on your gateway will change to the file’s values. Keys, tokens and passwords already there stay.",
            SettingsImportWords.ConfirmMessage(3));
        Assert.Equal("1 setting", SettingsImportWords.Settings(1));
        Assert.Equal("Settings imported. 2 settings changed.", SettingsImportWords.Done(2));
        Assert.Equal("The file matches your settings; nothing changed.", SettingsImportWords.Done(0));
        Assert.Equal(1, SettingsImportWords.ChangeCount(JsonValue.Create(5)));
        Assert.True(ConfigPath.ClearsEnabledToolsets(Obj("{\"toolsets\":[\"a\"]}"), Obj("{\"toolsets\":[]}")));
        Assert.False(ConfigPath.ClearsEnabledToolsets(Obj("{\"toolsets\":[]}"), Obj("{\"toolsets\":[]}")));
        Assert.False(ConfigPath.ClearsEnabledToolsets(Obj("{\"toolsets\":[\"a\"]}"), Obj("{}")));
    }

    // ------------------------------------------------------------------ Export Settings…

    [Fact]
    public async Task ExportReadsFreshAndSavesTheRedactedFile()
    {
        var (actions, _, gateway, ui, _) = Make(Obj(Golden("config.json")));
        await actions.ExportAsync();
        var (name, data) = Assert.Single(ui.Saved);
        Assert.Equal("Hermes settings 2026-11-21.json", name);
        Assert.Equal(Golden("export.json"), Encoding.UTF8.GetString(data));
        Assert.Equal([("GET", "/api/config")], gateway.Calls().Select(c => (c.Method, c.Path)));
        Assert.Empty(ui.Failures);
    }

    [Fact]
    public async Task ExportFailureIsCouldntExportSettingsWithTheLoadWords()
    {
        var (actions, _, gateway, ui, _) = Make();
        gateway.Fail["GET /api/config"] = () => ConfigHandler.Json(500, new JsonObject { ["detail"] = "disk full" });
        await actions.ExportAsync();
        Assert.Equal([("Couldn’t Export Settings", "disk full")], ui.Failures);
        Assert.Empty(ui.Saved);

        gateway.Fail["GET /api/config"] = () => ConfigHandler.Json(404, new JsonObject { ["detail"] = "Not Found" });
        await actions.ExportAsync();
        // SettingsErrorText.load: a 404 is an older Hermes, before the gateway's own words are considered.
        Assert.Equal(("Couldn’t Export Settings", "Not available on this Hermes. Updating Hermes may add it."), ui.Failures[1]);

        gateway.Fail["GET /api/config"] = () => new HttpResponseMessage(HttpStatusCode.NotFound) { Content = new StringContent("<html>") };
        await actions.ExportAsync();
        Assert.Equal(("Couldn’t Export Settings", "Not available on this Hermes. Updating Hermes may add it."), ui.Failures[2]);
    }

    // ------------------------------------------------------------------ Import Settings…

    [Theory]
    [InlineData("[1,2]")]
    [InlineData("\"text\"")]
    [InlineData("not json")]
    [InlineData("")]
    public async Task ImportRejectsAFileThatIsntSettings(string text)
    {
        var (actions, _, gateway, ui, _) = Make(Obj("{\"agent\":{\"max_turns\":1}}"));
        ui.Picked = new PickedSettingsFile(Encoding.UTF8.GetBytes(text));
        await actions.PickImportAsync();
        Assert.Equal([("Couldn’t Import Settings", "That file isn’t a Hermes settings file.")], ui.Failures);
        Assert.Empty(gateway.Calls());
        Assert.Empty(ui.Confirms);
    }

    [Fact]
    public async Task ImportOfAnUnreadableFileSaysTheSameAndACancelledPickDoesNothing()
    {
        var (actions, _, gateway, ui, _) = Make();
        ui.Picked = new PickedSettingsFile(null);
        await actions.PickImportAsync();
        Assert.Equal([("Couldn’t Import Settings", "That file isn’t a Hermes settings file.")], ui.Failures);
        ui.Picked = null;
        await actions.PickImportAsync();
        Assert.Single(ui.Failures);
        Assert.Empty(gateway.Calls());
    }

    [Fact]
    public async Task ImportConfirmsTheCountThenSendsTheSwiftPatch()
    {
        var (actions, store, gateway, ui, status) = Make(Obj(Golden("config.json")));
        ui.Picked = new PickedSettingsFile(Encoding.UTF8.GetBytes(Golden("import-file.json")));
        await actions.PickImportAsync();
        Assert.Equal([("Import Settings?", SettingsImportWords.ConfirmMessage(3), "Import")], ui.Confirms);
        var put = Assert.Single(gateway.Puts());
        Assert.True(JsonNode.DeepEquals(new JsonObject { ["config"] = JsonNode.Parse(Golden("import-patch.json")) }, put), put.ToJsonString());
        Assert.Equal("Settings imported. 3 settings changed.", status.Last());
        Assert.Equal([("Settings Imported", "3 settings changed.")], ui.Huds);
        // Secrets the file left out stayed on the gateway.
        Assert.Equal("plain-secret-value", gateway.Record["model"]!["api_key"]!.GetValue<string>());
        Assert.Equal("secret-in-list", gateway.Record["fallback_providers"]![0]!["api_key"]!.GetValue<string>());
        Assert.Equal(90, store.Value("agent.max_turns")!.GetValue<int>());
    }

    [Fact]
    public async Task ImportCancelledWritesNothingAndAMatchingFileSaysUnchanged()
    {
        var (actions, _, gateway, ui, status) = Make(Obj(Golden("config.json")));
        ui.Answer = false;
        ui.Picked = new PickedSettingsFile(Encoding.UTF8.GetBytes(Golden("import-file.json")));
        await actions.PickImportAsync();
        Assert.Single(ui.Confirms);
        Assert.Empty(gateway.Puts());

        ui.Picked = new PickedSettingsFile(Encoding.UTF8.GetBytes(Golden("export.json")));
        await actions.PickImportAsync();
        Assert.Single(ui.Confirms);
        Assert.Empty(gateway.Puts());
        Assert.Equal("The file matches your settings; nothing changed.", status.Last());
    }

    [Fact]
    public async Task ImportThatEmptiesToolsetsAsksFirst()
    {
        var (actions, _, gateway, ui, _) = Make(Obj("{\"toolsets\":[\"web\",\"memory\"]}"));
        ui.Picked = new PickedSettingsFile(Encoding.UTF8.GetBytes("{\"toolsets\":[]}"));
        await actions.PickImportAsync();
        Assert.Equal([("Remove All Tool Groups?", "This file turns off memory, terminal, web search, subagents and most other tools.", "Import Anyway")], ui.Confirms);
        Assert.True(JsonNode.DeepEquals(Obj("{\"config\":{\"toolsets\":[]}}"), Assert.Single(gateway.Puts())));
    }

    [Fact]
    public async Task ImportFailuresAreCouldntImportSettings()
    {
        // The fresh read failing: the load words.
        var (actions, _, gateway, ui, _) = Make(Obj("{\"agent\":{\"max_turns\":1}}"));
        ui.Picked = new PickedSettingsFile(Encoding.UTF8.GetBytes("{\"agent\":{\"max_turns\":2}}"));
        gateway.Fail["GET /api/config"] = () => ConfigHandler.Json(500, new JsonObject { ["detail"] = "<b>oops</b>" });
        await actions.PickImportAsync();
        Assert.Equal([("Couldn’t Import Settings", "Your gateway couldn’t send this list. Try again in a moment.")], ui.Failures);
        Assert.Empty(gateway.Puts());

        // The write failing: the save words.
        gateway.Fail["PUT /api/config"] = () => ConfigHandler.Json(500, new JsonObject { ["detail"] = "disk full" });
        await actions.PickImportAsync();
        Assert.Equal(("Couldn’t Import Settings", "disk full"), ui.Failures[1]);
        gateway.Fail["PUT /api/config"] = () => ConfigHandler.Json(200, new JsonObject { ["ok"] = false });
        await actions.PickImportAsync();
        Assert.Equal(("Couldn’t Import Settings", "Your gateway didn’t accept the change."), ui.Failures[2]);
        Assert.Empty(ui.Huds);
    }

    // ------------------------------------------------------------------ Reset to Defaults…

    [Fact]
    public async Task ResetAsksThenSendsTheDefaultsWhole()
    {
        var (actions, store, gateway, ui, status) = Make(Obj("{\"agent\":{\"max_turns\":120},\"toolsets\":[\"web\"]}"));
        ui.Answer = false;
        await actions.ConfirmResetAsync();
        Assert.Equal([("Reset All Settings to Defaults?",
            "Every setting on the computer running Hermes goes back to its Hermes default. Keys, bots and chats stay. Export Settings… first to keep a copy.",
            "Reset to Defaults")], ui.Confirms);
        Assert.Empty(gateway.Calls());

        ui.Answer = true;
        var resetting = new List<bool>();
        actions.ResettingChanged += r => resetting.Add(r);
        await actions.ConfirmResetAsync();
        var calls = gateway.Calls().Select(c => (c.Method, c.Path)).ToList();
        Assert.Equal(("GET", "/api/config/defaults"), calls[0]);
        Assert.Equal(("PUT", "/api/config"), calls[1]);
        Assert.True(JsonNode.DeepEquals(new JsonObject { ["config"] = gateway.Defaults.DeepClone() }, Assert.Single(gateway.Puts())));
        Assert.Equal(["Resetting…", "Settings reset to Hermes defaults."], status.Where(s => s != null));
        Assert.Equal([true, false], resetting);
        Assert.False(actions.Resetting);
        Assert.Equal(90, store.Value("agent.max_turns")!.GetValue<int>());
    }

    [Fact]
    public async Task ResetFailureIsCouldntResetSettings()
    {
        var (actions, _, gateway, ui, status) = Make();
        gateway.Fail["GET /api/config/defaults"] = () => ConfigHandler.Json(500, new JsonObject { ["detail"] = "disk full" });
        await actions.ConfirmResetAsync();
        Assert.Equal([("Couldn’t Reset Settings", "disk full")], ui.Failures);
        Assert.Null(status.Last());
        Assert.Empty(gateway.Puts());

        gateway.Fail["PUT /api/config"] = () => ConfigHandler.Json(502, new JsonObject());
        await actions.ConfirmResetAsync();
        Assert.Equal(("Couldn’t Reset Settings", "Your gateway didn’t accept the change."), ui.Failures[1]);
        Assert.False(actions.Resetting);
    }

    [Fact]
    public void FooterAndButtonWords()
    {
        Assert.Equal("Export Settings…", SettingsFileWords.Export);
        Assert.Equal("Import Settings…", SettingsFileWords.Import);
        Assert.Equal("Clear Model Favorites…", SettingsFileWords.ClearModels);
        Assert.Equal("Reset to Defaults…", SettingsFileWords.Reset);
        Assert.Equal("Exported files leave out keys, tokens and passwords.", SettingsFileWords.Footer);
    }
    // ------------------------------------------------------------------ [WIN-06a] Clear Model Favorites…

    /// `SettingsWords.clearModelsMessage(favorites:recents:)` (HermesKit/Settings/SettingsWords.swift, 93f984bb1).
    [Theory]
    [InlineData(0, 0, "No models are starred or recent on this device. Bots, chats and each bot’s default model stay.")]
    [InlineData(1, 0, "Unstars 1 model. Bots, chats and each bot’s default model stay.")]
    [InlineData(3, 0, "Unstars 3 models. Bots, chats and each bot’s default model stay.")]
    [InlineData(0, 1, "Forgets 1 recent model. Bots, chats and each bot’s default model stay.")]
    [InlineData(0, 2, "Forgets 2 recent models. Bots, chats and each bot’s default model stay.")]
    [InlineData(2, 1, "Unstars 2 models and forgets 1 recent model. Bots, chats and each bot’s default model stay.")]
    [InlineData(1, 3, "Unstars 1 model and forgets 3 recent models. Bots, chats and each bot’s default model stay.")]
    public void ClearModelsMessageReadsAsTheMacs(int favorites, int recents, string words) =>
        Assert.Equal(words, SettingsWords.ClearModelsMessage(favorites, recents));

    private static (Hermes.Core.Composer.ModelPrefs Mine, Hermes.Core.Composer.ModelPrefs Other, Hermes.Core.Composer.MemoryStore Store) StarredPrefs()
    {
        var store = new Hermes.Core.Composer.MemoryStore();
        var mine = new Hermes.Core.Composer.ModelPrefs("http://127.0.0.1:9|qa", store);
        var other = new Hermes.Core.Composer.ModelPrefs("http://127.0.0.1:8|qa", store);
        mine.ToggleFavorite("nous", "fixture-model-a");
        mine.ToggleFavorite("openrouter", "fixture-model-b");
        mine.Remember(new Hermes.Core.Composer.ModelChoice("fixture-model-c", "Fixture C", "nous"));
        mine.SetPreset("nous", "fixture-model-a", new Hermes.Core.Composer.ModelPreset("high", true));
        mine.SetFoldedProviders(["openrouter"]);
        mine.ToggleFavoriteCommand("/fixture");
        other.ToggleFavorite("nous", "fixture-model-z");
        other.Remember(new Hermes.Core.Composer.ModelChoice("fixture-model-y", "Fixture Y", "nous"));
        return (mine, other, store);
    }

    /// `SettingsFileActions.confirmClearModels` (App/Settings/SettingsNavigator.swift, 93f984bb1): asks with this
    /// account's counts; Cancel keeps everything; Clear empties this account's stars and recents on this device only,
    /// says so under the buttons, and the gateway hears nothing.
    [Fact]
    public async Task ClearModelsAsksThenClearsThisAccountsStarsAndRecentsOnly()
    {
        var (_, store, gateway, ui, status) = Make();
        var (mine, other, _) = StarredPrefs();
        var lines = new List<string>();
        var before = SettingsFileActions.Log;
        SettingsFileActions.Log = line => { lock (lines) lines.Add(line); };
        try
        {
            var actions = new SettingsFileActions(store, ui) { Models = mine };
            actions.StatusChanged += s => { lock (status) status.Add(s); };

            ui.Answer = false;
            await actions.ConfirmClearModelsAsync();
            Assert.Equal([("Clear Favorite & Recent Models?",
                "Unstars 2 models and forgets 1 recent model. Bots, chats and each bot’s default model stay.", "Clear")], ui.Confirms);
            Assert.Equal(2, mine.Favorites.Count);
            Assert.Single(mine.Recents);
            Assert.All(status, s => Assert.Null(s));

            ui.Answer = true;
            await actions.ConfirmClearModelsAsync();
            Assert.Equal(2, ui.Confirms.Count);
            Assert.Empty(mine.Favorites);
            Assert.Empty(mine.Recents);
            Assert.Equal("Favorite and recent models cleared.", status.Last());
            Assert.Contains("model favourites and recents cleared", lines);
            // Only stars and recents: presets, folded sections and starred commands stay, and so does another account.
            Assert.Equal("high", mine.Preset("nous", "fixture-model-a").Effort);
            Assert.Contains("openrouter", mine.FoldedProviders);
            Assert.Equal(["/fixture"], mine.FavoriteCommands);
            Assert.Equal(["nous::fixture-model-z"], other.Favorites);
            Assert.Single(other.Recents);
            // Device-local: no gateway call at all.
            Assert.Empty(gateway.Calls());
            Assert.Empty(ui.Failures);
            Assert.Empty(ui.Huds);

            // Asked again with nothing left: the Mac's words for none, and Clear still answers.
            await actions.ConfirmClearModelsAsync();
            Assert.Equal("No models are starred or recent on this device. Bots, chats and each bot’s default model stay.", ui.Confirms.Last().Message);
            Assert.Equal("Favorite and recent models cleared.", status.Last());
        }
        finally { SettingsFileActions.Log = before; }
    }

    /// The counts are read when it asks (the Mac builds the message before the alert), and an earlier status is cleared.
    [Fact]
    public async Task ClearModelsClearsAnEarlierStatusAndCountsWhenAsked()
    {
        var (_, store, _, ui, status) = Make();
        var (mine, _, _) = StarredPrefs();
        var actions = new SettingsFileActions(store, ui) { Models = mine };
        actions.StatusChanged += s => { lock (status) status.Add(s); };
        mine.ToggleFavorite("nous", "fixture-model-a");   // unstarred: one left
        ui.Answer = false;
        await actions.ConfirmClearModelsAsync();
        Assert.Equal("Unstars 1 model and forgets 1 recent model. Bots, chats and each bot’s default model stay.", ui.Confirms.Single().Message);
        Assert.Equal([null], status);
    }

    /// No signed-in account (the Mac's `guard let account`): nothing is asked and nothing changes.
    [Fact]
    public async Task ClearModelsWithoutAnAccountDoesNothing()
    {
        var (actions, _, gateway, ui, status) = Make();
        await actions.ConfirmClearModelsAsync();
        Assert.Empty(ui.Confirms);
        Assert.Empty(status);
        Assert.Empty(gateway.Calls());
    }

    // ------------------------------------------------------------------ Settings search (SettingsSearch.actions, SettingsNavigator.open)

    /// HermesKit/Settings/SettingsSearch.swift `actions`: the file actions as search entries, context "About" on the
    /// desktop (`DeviceWord.isMac`), each targeting `.action(id)`, in the Mac's order: export, import, clear-models, reset
    /// (SettingsSearch.swift:211-216, 93f984bb1; the desktop label is "Clear Model Favorites…", the button's).
    [Fact]
    public void FileActionsAreSearchEntriesUnderAbout()
    {
        var index = SettingsSearch.Index;
        var actions = index.Where(e => e.Target.StartsWith(SettingsSearch.ActionPrefix, StringComparison.Ordinal)).ToList();
        Assert.Equal(["action:export", "action:import", "action:clear-models", "action:reset"], actions.Select(e => e.Id));
        Assert.Equal(["Export Settings…", "Import Settings…", "Clear Model Favorites…", "Reset to Defaults…"], actions.Select(e => e.Label));
        Assert.Equal([SettingsFileWords.Export, SettingsFileWords.Import, SettingsFileWords.ClearModels, SettingsFileWords.Reset], actions.Select(e => e.Label));
        Assert.Equal(["Hermes", "Hermes", "Chat", "Hermes"], actions.Select(e => e.Context));
        Assert.All(actions, e => Assert.False(e.IsPage));
        Assert.Equal(["action:export", "action:import", "action:clear-models", "action:reset"], actions.Select(e => e.Target));
        Assert.Equal(["export", "backup", "save settings", "download"], actions[0].Keywords);
        Assert.Equal(["import", "restore", "load settings", "upload"], actions[1].Keywords);
        Assert.Equal(["favorites", "favourites", "starred models", "recent models", "unstar", "clear"], actions[2].Keywords);
        Assert.Equal(["reset", "defaults", "factory", "restore defaults"], actions[3].Keywords);
        // As the Mac's index() ends: the actions come last.
        Assert.Equal(actions, index.TakeLast(4).ToList());
        Assert.Equal(SettingsCategory.Gateway, SettingsSearch.Category("action:export"));
        Assert.Equal(SettingsCategory.Gateway, SettingsSearch.Category("action:import"));
        Assert.Equal(SettingsCategory.Chat, SettingsSearch.Category("action:clear-models"));
        Assert.Equal(SettingsCategory.Gateway, SettingsSearch.Category("action:reset"));
        Assert.Equal(["export", "import", "clear-models", "reset"], actions.Select(e => SettingsSearch.ActionId(e.Target)));
        Assert.Null(SettingsSearch.ActionId("about"));
        Assert.Null(SettingsSearch.ActionId("row:ui-scale"));
    }

    [Fact]
    public void SearchFindsTheFileActionsByTheirWords()
    {
        var index = SettingsSearch.Index;
        Assert.Equal(["Export Settings…"], SettingsSearch.Results("backup", index).Select(e => e.Label));
        // Words match inside words, as the Mac's do: "load" is in Export's "download".
        Assert.Equal(["Export Settings…", "Import Settings…"], SettingsSearch.Results("load settings", index).Select(e => e.Label));
        Assert.Equal(["Reset to Defaults…"], SettingsSearch.Results("factory", index).Select(e => e.Label));
        Assert.Contains(SettingsSearch.Results("restore", index), e => e.Id == "action:import");
        Assert.Contains(SettingsSearch.Results("restore", index), e => e.Id == "action:reset");
        Assert.Contains(SettingsSearch.Results("export", index), e => e.Id == "action:export");
        Assert.Contains(SettingsSearch.Results("reset hermes", index), e => e.Id == "action:reset");
        Assert.Equal(["Clear Model Favorites…"], SettingsSearch.Results("unstar", index).Select(e => e.Label));
        Assert.Contains(SettingsSearch.Results("starred models", index), e => e.Id == "action:clear-models");
        Assert.Contains(SettingsSearch.Results("favourites", index), e => e.Id == "action:clear-models");
        Assert.Contains(SettingsSearch.Results("recent models", index), e => e.Id == "action:clear-models");
    }

    /// SettingsNavigator.open `.action(id)`: "export" → export(), "import" → pickImport(), "clear-models" →
    /// confirmClearModels(), anything else → confirmReset().
    [Theory]
    [InlineData("action:export", "save Hermes settings 2026-11-21.json")]
    [InlineData("action:import", "pick")]
    [InlineData("action:reset", "confirm Reset All Settings to Defaults?")]
    [InlineData("action:clear-models", "confirm Clear Favorite & Recent Models?")]
    [InlineData("action:something-else", "confirm Reset All Settings to Defaults?")]
    public async Task ASearchResultRunsItsAction(string target, string first)
    {
        var (_, store, gateway, ui, _) = Make(Obj("""{"agent":{"max_turns":5}}"""));
        var (mine, _, _) = StarredPrefs();
        // Make()'s clock, so the export case names the same day.
        var actions = new SettingsFileActions(store, ui) { Models = mine, Now = () => new DateTime(2026, 11, 21, 23, 30, 0, DateTimeKind.Local) };
        ui.Answer = false;
        ui.SaveChosen = false;
        Assert.True(await actions.OpenAsync(target));
        Assert.Equal([first], ui.Log);
        Assert.Empty(gateway.Puts());
    }

    /// The clear-models result is Clear Model Favorites…'s own confirm (never Reset's): Cancel keeps the stars and recents
    /// and Clear empties them, and neither reaches the gateway.
    [Fact]
    public async Task TheClearModelsResultAsksAsItsButtonDoes()
    {
        var (_, store, gateway, ui, status) = Make(Obj("""{"agent":{"max_turns":5}}"""));
        var (mine, _, _) = StarredPrefs();
        var actions = new SettingsFileActions(store, ui) { Models = mine };
        actions.StatusChanged += s => { lock (status) status.Add(s); };
        ui.Answer = false;
        Assert.True(await actions.OpenAsync("action:clear-models"));
        Assert.Equal([("Clear Favorite & Recent Models?",
            "Unstars 2 models and forgets 1 recent model. Bots, chats and each bot’s default model stay.", "Clear")], ui.Confirms);
        Assert.Equal(2, mine.Favorites.Count);
        ui.Answer = true;
        Assert.True(await actions.OpenAsync("action:clear-models"));
        Assert.Empty(mine.Favorites);
        Assert.Empty(mine.Recents);
        Assert.Equal("Favorite and recent models cleared.", status.Last());
        Assert.DoesNotContain(ui.Confirms, c => c.Title == "Reset All Settings to Defaults?");
        Assert.Empty(gateway.Calls());
    }

    [Fact]
    public async Task ATargetThatIsNoActionRunsNothing()
    {
        var (actions, _, gateway, ui, _) = Make();
        foreach (var target in new[] { "about", "row:ui-scale", "diagnostics", "action", "" })
            Assert.False(await actions.OpenAsync(target));
        Assert.Empty(ui.Log);
        Assert.Empty(gateway.Calls());
    }
}
