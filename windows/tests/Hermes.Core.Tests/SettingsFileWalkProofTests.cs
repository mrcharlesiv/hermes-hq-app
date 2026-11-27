using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// [WIN-06] The checks behind the settings-file walk (HermesHQ.Windows Services/ProofWalks.SettingsFile.cs) on
/// settings-gateway.py's `GET /__settings/state` record, and the Mac's words its dialogs must read
/// (App/Settings/SettingsNavigator.swift, HermesKit/Settings/SettingsImportWords.swift at 93f984bb1). All data synthetic.
public class SettingsFileWalkProofTests
{
    private static JsonNode State(params (string Kind, string Method, string Path, JsonObject? Config, double At)[] entries)
    {
        var writes = new JsonArray();
        var rest = new JsonArray();
        foreach (var (kind, method, path, config, at) in entries)
        {
            if (kind == "write")
                writes.Add(new JsonObject { ["method"] = method, ["params"] = new JsonObject { ["profile"] = "default", ["config"] = config }, ["at"] = at });
            else
                rest.Add(new JsonObject { ["method"] = method, ["path"] = path, ["at"] = at });
        }
        return new JsonObject { ["writes"] = writes, ["rest"] = rest };
    }

    private static readonly JsonObject Defaults = new() { ["agent"] = new JsonObject { ["max_turns"] = 90 }, ["timezone"] = "" };

    [Fact]
    public void TheDialogsReadTheMacsWords()
    {
        Assert.Null(SettingsFileWalkProof.ResetConfirmReads("Reset All Settings to Defaults?",
            "Every setting on the computer running Hermes goes back to its Hermes default. Keys, bots and chats stay. Export Settings\u2026 first to keep a copy.",
            "Reset to Defaults", "Cancel"));
        Assert.NotNull(SettingsFileWalkProof.ResetConfirmReads("Reset All Settings to Defaults?", "Every setting goes back.", "Reset to Defaults", "Cancel"));
        Assert.NotNull(SettingsFileWalkProof.ResetConfirmReads("Reset All Settings to Defaults?",
            "Every setting on the computer running Hermes goes back to its Hermes default. Keys, bots and chats stay. Export Settings\u2026 first to keep a copy.",
            "Reset to Defaults", "OK"));

        Assert.Null(SettingsFileWalkProof.NotSettingsReads("Couldn\u2019t Import Settings", "That file isn\u2019t a Hermes settings file.", "OK"));
        Assert.NotNull(SettingsFileWalkProof.NotSettingsReads("Couldn't Import Settings", "That file isn\u2019t a Hermes settings file.", "OK"));

        Assert.Null(SettingsFileWalkProof.ImportConfirmReads("Import Settings?",
            "1 setting on your gateway will change to the file\u2019s values. Keys, tokens and passwords already there stay.", "Import", "Cancel"));
        Assert.NotNull(SettingsFileWalkProof.ImportConfirmReads("Import Settings?",
            "2 settings on your gateway will change to the file\u2019s values. Keys, tokens and passwords already there stay.", "Import", "Cancel"));

        Assert.Null(SettingsFileWalkProof.ImportedReads("Settings Imported", "1 setting changed.", "Settings imported. 1 setting changed."));
        Assert.NotNull(SettingsFileWalkProof.ImportedReads("Settings Imported", "1 setting changed.", "The file matches your settings; nothing changed."));
        Assert.Equal("Settings reset to Hermes defaults.", SettingsFileWalkProof.ResetDone);
        Assert.Equal("Exported files leave out keys, tokens and passwords.", SettingsFileWalkProof.Footer);
    }

    [Fact]
    public void TheExportIsNamedForTodayAndHoldsNoStandInCredential()
    {
        var today = new DateTime(2026, 11, 22, 9, 30, 0);
        Assert.Null(SettingsFileWalkProof.ExportNamed("Hermes settings 2026-11-22.json", today));
        Assert.NotNull(SettingsFileWalkProof.ExportNamed("Hermes settings 2026-11-21.json", today));
        Assert.NotNull(SettingsFileWalkProof.ExportNamed("Hermes Settings 2026-11-22.json", today));

        var clean = Encoding.UTF8.GetBytes("{\n  \"agent\" : {\n    \"max_turns\" : 120\n  }\n}");
        Assert.Null(SettingsFileWalkProof.ExportClean(clean));
        var leaky = Encoding.UTF8.GetBytes("{\"mcp_servers\":{\"github\":{\"headers\":{\"Authorization\":\"Bearer fixture-bearer-not-real-0000\"}}}}");
        Assert.Contains("fixture-bearer-not-real-0000", SettingsFileWalkProof.ExportClean(leaky));
        Assert.NotNull(SettingsFileWalkProof.ExportClean(Encoding.UTF8.GetBytes("[1,2]")));
        Assert.NotNull(SettingsFileWalkProof.ExportClean(null));
    }

    [Fact]
    public void TheWalksEditChangesOneSettingAndItsPatchIsThatAlone()
    {
        var export = Encoding.UTF8.GetBytes("{\"agent\":{\"max_turns\":120,\"image_input_mode\":\"auto\"},\"timezone\":\"\"}");
        var (edited, patch) = SettingsFileWalkProof.Edit(export);
        var file = JsonNode.Parse(edited)!;
        Assert.Equal(SettingsFileWalkProof.EditedMaxTurns, file["agent"]!["max_turns"]!.GetValue<long>());
        Assert.Equal("auto", file["agent"]!["image_input_mode"]!.GetValue<string>());
        Assert.True(JsonNode.DeepEquals(new JsonObject { ["agent"] = new JsonObject { ["max_turns"] = SettingsFileWalkProof.EditedMaxTurns } }, patch));
        // Already at the walk's value: the edit would change nothing, so the walk says so rather than proving nothing.
        Assert.Throws<InvalidOperationException>(() => SettingsFileWalkProof.Edit(Encoding.UTF8.GetBytes(
            $"{{\"agent\":{{\"max_turns\":{SettingsFileWalkProof.EditedMaxTurns}}}}}")));
    }

    [Fact]
    public void NothingWrittenSeesOnlyLaterPuts()
    {
        var state = State(("write", "PUT /api/config", "", new JsonObject(), 5), ("rest", "GET", "/api/config", null, 12));
        Assert.Null(SettingsFileWalkProof.NothingWritten(state, 10, "Cancel"));
        Assert.Contains("Cancel", SettingsFileWalkProof.NothingWritten(state, 4, "Cancel"));
        Assert.Null(SettingsFileWalkProof.NoDefaultsRead(state, 4, "Cancel"));
        Assert.Equal(12, SettingsFileWalkProof.Mark(state));
        Assert.Equal(0, SettingsFileWalkProof.Mark(State()));
        var read = State(("rest", "GET", "/api/config/defaults", null, 12));
        Assert.NotNull(SettingsFileWalkProof.NoDefaultsRead(read, 10, "Cancel"));
    }

    [Fact]
    public void TheImportWritesExactlyThePatch()
    {
        var patch = new JsonObject { ["agent"] = new JsonObject { ["max_turns"] = 77 } };
        Assert.Null(SettingsFileWalkProof.ImportWritten(State(("write", "PUT /api/config", "", (JsonObject)patch.DeepClone(), 11)), 10, patch));
        Assert.Contains("0", SettingsFileWalkProof.ImportWritten(State(), 10, patch));
        Assert.NotNull(SettingsFileWalkProof.ImportWritten(State(("write", "PUT /api/config", "", new JsonObject { ["agent"] = new JsonObject { ["max_turns"] = 78 } }, 11)), 10, patch));
        Assert.NotNull(SettingsFileWalkProof.ImportWritten(State(
            ("write", "PUT /api/config", "", (JsonObject)patch.DeepClone(), 11), ("write", "PUT /api/config", "", (JsonObject)patch.DeepClone(), 12)), 10, patch));
        // A credential sent back to the gateway fails it even inside the right shape.
        var leaky = new JsonObject { ["agent"] = new JsonObject { ["max_turns"] = 77 }, ["providers"] = new JsonObject { ["x"] = new JsonObject { ["api_key"] = "fixture-bearer-not-real-0000" } } };
        Assert.NotNull(SettingsFileWalkProof.ImportWritten(State(("write", "PUT /api/config", "", leaky, 11)), 10, leaky));
    }

    [Fact]
    public void ResetReadsTheDefaultsThenWritesThemOnce()
    {
        Assert.Null(SettingsFileWalkProof.ResetWritten(State(
            ("rest", "GET", "/api/config/defaults", null, 11), ("write", "PUT /api/config", "", (JsonObject)Defaults.DeepClone(), 12)), 10, Defaults));
        // No GET of the defaults first.
        Assert.NotNull(SettingsFileWalkProof.ResetWritten(State(("write", "PUT /api/config", "", (JsonObject)Defaults.DeepClone(), 12)), 10, Defaults));
        // The PUT before the GET.
        Assert.NotNull(SettingsFileWalkProof.ResetWritten(State(
            ("write", "PUT /api/config", "", (JsonObject)Defaults.DeepClone(), 11), ("rest", "GET", "/api/config/defaults", null, 12)), 10, Defaults));
        // Something other than the defaults written.
        Assert.NotNull(SettingsFileWalkProof.ResetWritten(State(
            ("rest", "GET", "/api/config/defaults", null, 11), ("write", "PUT /api/config", "", new JsonObject { ["timezone"] = "" }, 12)), 10, Defaults));
        // Two PUTs.
        Assert.NotNull(SettingsFileWalkProof.ResetWritten(State(
            ("rest", "GET", "/api/config/defaults", null, 11), ("write", "PUT /api/config", "", (JsonObject)Defaults.DeepClone(), 12),
            ("write", "PUT /api/config", "", (JsonObject)Defaults.DeepClone(), 13)), 10, Defaults));
        // A GET with a profile: the Mac's reset reads Hermes' defaults, never per profile.
        Assert.NotNull(SettingsFileWalkProof.ResetWritten(State(
            ("rest", "GET", "/api/config/defaults?profile=sam", null, 11), ("write", "PUT /api/config", "", (JsonObject)Defaults.DeepClone(), 12)), 10, Defaults));
    }
    /// [WIN-06a] Clear Model Favorites…'s confirmation (App/Settings/SettingsNavigator.swift `confirmClearModels`,
    /// HermesKit/Settings/SettingsWords.swift `clearModelsMessage`, 93f984bb1) for the walk's 2 stars and 1 recent.
    [Fact]
    public void ClearModelsConfirmReadsTheMacsWords()
    {
        const string two = "Unstars 2 models and forgets 1 recent model. Bots, chats and each bot\u2019s default model stay.";
        Assert.Null(SettingsFileWalkProof.ClearModelsConfirmReads("Clear Favorite & Recent Models?", two, "Clear", "Cancel", 2, 1));
        Assert.NotNull(SettingsFileWalkProof.ClearModelsConfirmReads("Clear Favorite & Recent Models?", two, "Clear", "Cancel", 1, 1));
        Assert.NotNull(SettingsFileWalkProof.ClearModelsConfirmReads("Clear Favorite and Recent Models?", two, "Clear", "Cancel", 2, 1));
        Assert.NotNull(SettingsFileWalkProof.ClearModelsConfirmReads("Clear Favorite & Recent Models?", two, "Clear All", "Cancel", 2, 1));
        Assert.NotNull(SettingsFileWalkProof.ClearModelsConfirmReads("Clear Favorite & Recent Models?", two, "Clear", "OK", 2, 1));
        Assert.Null(SettingsFileWalkProof.ClearModelsConfirmReads("Clear Favorite & Recent Models?",
            "No models are starred or recent on this device. Bots, chats and each bot\u2019s default model stay.", "Clear", "Cancel", 0, 0));
        Assert.Null(SettingsFileWalkProof.ClearModelsConfirmReads("Clear Favorite & Recent Models?",
            "Forgets 2 recent models. Bots, chats and each bot\u2019s default model stay.", "Clear", "Cancel", 0, 2));
        Assert.Null(SettingsFileWalkProof.ClearModelsConfirmReads("Clear Favorite & Recent Models?",
            "Unstars 1 model. Bots, chats and each bot\u2019s default model stay.", "Clear", "Cancel", 1, 0));
        Assert.Equal("Clear Model Favorites\u2026", SettingsFileWalkProof.ClearModels);
        Assert.Equal("Favorite and recent models cleared.", SettingsFileWalkProof.ClearModelsDone);
    }

    /// The four buttons in the Mac's order: Export, Import, Clear Model Favorites, Reset.
    [Fact]
    public void TheButtonsAreTheMacsFourInOrder()
    {
        Assert.Null(SettingsFileWalkProof.ButtonsRead(["Export Settings\u2026", "Import Settings\u2026", "Clear Model Favorites\u2026", "Reset to Defaults\u2026"]));
        Assert.NotNull(SettingsFileWalkProof.ButtonsRead(["Export Settings\u2026", "Import Settings\u2026", "Reset to Defaults\u2026"]));
        Assert.NotNull(SettingsFileWalkProof.ButtonsRead(["Export Settings\u2026", "Import Settings\u2026", "Reset to Defaults\u2026", "Clear Model Favorites\u2026"]));
    }

    /// Clearing model stars is device-local: after the mark, no write of any kind, no non-GET request and no read of the
    /// config may reach the stand-in (an unrelated background GET is not the action's).
    [Fact]
    public void NoSettingsCallSeesWritesAndConfigReadsAfterTheMark()
    {
        Assert.Null(SettingsFileWalkProof.NoSettingsCall(State(), 10, "Clear"));
        Assert.Null(SettingsFileWalkProof.NoSettingsCall(State(("rest", "GET", "/api/status", null, 11)), 10, "Clear"));
        Assert.Null(SettingsFileWalkProof.NoSettingsCall(State(("write", "PUT /api/config", "", new JsonObject(), 9), ("rest", "GET", "/api/config", null, 9)), 10, "Clear"));
        Assert.Contains("Clear", SettingsFileWalkProof.NoSettingsCall(State(("write", "PUT /api/config", "", new JsonObject(), 11)), 10, "Clear"));
        Assert.NotNull(SettingsFileWalkProof.NoSettingsCall(State(("write", "config.set", "", new JsonObject(), 11)), 10, "Clear"));
        Assert.NotNull(SettingsFileWalkProof.NoSettingsCall(State(("rest", "GET", "/api/config", null, 11)), 10, "Clear"));
        Assert.NotNull(SettingsFileWalkProof.NoSettingsCall(State(("rest", "GET", "/api/config/defaults", null, 11)), 10, "Clear"));
        Assert.NotNull(SettingsFileWalkProof.NoSettingsCall(State(("rest", "POST", "/api/anything", null, 11)), 10, "Clear"));
    }
}
