using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Net;
using Hermes.Core.Settings;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// [WIN-06] The settings-file walk's sequence (Services/ProofWalks.SettingsFile.cs) run through SettingsFileActions on
/// settings-gateway.py, with the walk's own checks (`SettingsFileWalkProof`) judged on the stand-in's real record: so the
/// checks the Windows walk relies on are known to hold, and to catch a wrong write, before CI. Run through
/// windows/scripts/e2e.sh (HQW_E2E_SETTINGS_CREDENTIALS); without it this passes vacuously. All data synthetic.
[Trait("Category", "E2E")]
[Collection(SettingsStandIn.Name)]
public class SettingsFileWalkEndToEndTests
{
    private sealed class WalkUi : ISettingsFileUi
    {
        public readonly List<(string Title, string? Message, string Action)> Confirms = [];
        public readonly List<(string Title, string Reason)> Failures = [];
        public readonly List<(string Title, string Detail)> Huds = [];
        public (string Name, byte[] Data)? Saved;
        public bool Answer = true;
        public PickedSettingsFile? Picked;
        public Task<bool> ConfirmAsync(string title, string? message, string action) { Confirms.Add((title, message, action)); return Task.FromResult(Answer); }
        public Task<bool> SaveAsync(string fileName, byte[] data) { Saved = (fileName, data); return Task.FromResult(true); }
        public Task<PickedSettingsFile?> PickAsync() => Task.FromResult(Picked);
        public void Fail(string title, string reason) => Failures.Add((title, reason));
        public void Done(string title, string detail) => Huds.Add((title, detail));
    }

    private static async Task<JsonNode> State(string url)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + "/__settings/state"))!;
    }

    private static async Task Post(string url, string path, object body)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");
        (await http.PostAsync(url.TrimEnd('/') + path, content)).EnsureSuccessStatusCode();
    }

    private static double Mark(JsonNode state) => SettingsFileWalkProof.Mark(state);

    [Fact]
    public async Task TheWalksChecksHoldOnTheStandInsRecord()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_SETTINGS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Post(url, "/__settings/reset", new { });
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        var store = new GatewayConfigStore(new GatewayConfigApi(session));
        var ui = new WalkUi();
        string? status = null;
        var today = DateTime.Now;
        // [WIN-06a] This account's stars and recents on this device (synthetic), as the walk seeds them.
        var models = new Hermes.Core.Composer.ModelPrefs(url + "|" + cred.Str("username"), new Hermes.Core.Composer.MemoryStore());
        models.ToggleFavorite("nous", "fixture-model-a");
        models.ToggleFavorite("openrouter", "fixture-model-b");
        models.Remember(new Hermes.Core.Composer.ModelChoice("fixture-model-c", "Fixture C", "nous"));
        var actions = new SettingsFileActions(store, ui) { Now = () => today, Models = models };
        actions.StatusChanged += s => status = s;

        // Export: named for today, no stand-in credential, nothing written.
        var mark = Mark(await State(url));
        await actions.ExportAsync();
        var (name, data) = ui.Saved ?? throw new InvalidOperationException("nothing exported");
        Assert.Null(SettingsFileWalkProof.ExportNamed(name, today));
        Assert.Null(SettingsFileWalkProof.ExportClean(data));
        Assert.Null(SettingsFileWalkProof.NothingWritten(await State(url), mark, "Export"));

        // Not a settings file: the Mac's alert, nothing written.
        mark = Mark(await State(url));
        ui.Picked = new PickedSettingsFile("[\"not\", \"settings\"]"u8.ToArray());
        await actions.PickImportAsync();
        var (failTitle, failReason) = Assert.Single(ui.Failures);
        Assert.Null(SettingsFileWalkProof.NotSettingsReads(failTitle, failReason, "OK"));
        Assert.Null(SettingsFileWalkProof.NothingWritten(await State(url), mark, "a JSON array"));

        // The walk's edit of its own export: the one-setting confirmation, then exactly its patch written.
        var (edited, patch) = SettingsFileWalkProof.Edit(data);
        mark = Mark(await State(url));
        ui.Picked = new PickedSettingsFile(edited);
        await actions.PickImportAsync();
        var (confirmTitle, confirmMessage, confirmAction) = Assert.Single(ui.Confirms);
        Assert.Null(SettingsFileWalkProof.ImportConfirmReads(confirmTitle, confirmMessage, confirmAction, "Cancel"));
        var (hudTitle, hudDetail) = Assert.Single(ui.Huds);
        Assert.Null(SettingsFileWalkProof.ImportedReads(hudTitle, hudDetail, status));
        var afterImport = await State(url);
        Assert.Null(SettingsFileWalkProof.ImportWritten(afterImport, mark, patch));
        // The same record judged against another patch fails: the check isn't vacuous.
        Assert.NotNull(SettingsFileWalkProof.ImportWritten(afterImport, mark, new JsonObject { ["agent"] = new JsonObject { ["max_turns"] = 78 } }));

        // [WIN-06a] Clear Model Favorites…: the Mac's words for 2 stars and 1 recent; Cancel keeps them; Clear empties
        // them and says so, and the gateway hears nothing either way.
        mark = Mark(await State(url));
        ui.Answer = false;
        await actions.ConfirmClearModelsAsync();
        var (clearTitle, clearMessage, clearAction) = ui.Confirms.Last();
        Assert.Null(SettingsFileWalkProof.ClearModelsConfirmReads(clearTitle, clearMessage, clearAction, "Cancel", 2, 1));
        Assert.Equal(2, models.Favorites.Count);
        ui.Answer = true;
        await actions.ConfirmClearModelsAsync();
        Assert.Empty(models.Favorites);
        Assert.Empty(models.Recents);
        Assert.Equal(SettingsFileWalkProof.ClearModelsDone, status);
        Assert.Null(SettingsFileWalkProof.NoSettingsCall(await State(url), mark, "Clear Model Favorites"));

        // Reset: Cancel reads and writes nothing; Reset to Defaults reads Hermes' defaults then writes them once.
        mark = Mark(await State(url));
        ui.Answer = false;
        await actions.ConfirmResetAsync();
        var (resetTitle, resetMessage, resetAction) = ui.Confirms.Last();
        Assert.Null(SettingsFileWalkProof.ResetConfirmReads(resetTitle, resetMessage, resetAction, "Cancel"));
        var cancelled = await State(url);
        Assert.Null(SettingsFileWalkProof.NothingWritten(cancelled, mark, "Cancel"));
        Assert.Null(SettingsFileWalkProof.NoDefaultsRead(cancelled, mark, "Cancel"));
        ui.Answer = true;
        await actions.ConfirmResetAsync();
        Assert.Equal(SettingsFileWalkProof.ResetDone, status);
        var reset = await State(url);
        var defaults = await store.DefaultsAsync();
        Assert.Null(SettingsFileWalkProof.ResetWritten(reset, mark, defaults));
        Assert.NotNull(SettingsFileWalkProof.ResetWritten(reset, mark, patch));
    }
}
