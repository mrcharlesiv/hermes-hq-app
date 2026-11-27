using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hermes.Core.Shell;

/// [WIN-06] What the settings-file walk (HermesHQ.Windows Services/ProofWalks.SettingsFile.cs) checks: the Mac's words in
/// its dialogs (spelled out here, not taken from SettingsFileWords, so a change there fails the walk), the exported file,
/// and settings-gateway.py's own record (`GET /__settings/state`: `writes` holds each PUT with its body, `rest` each
/// request's method and path). Each answers null when so, else what is wrong. Kept apart from WalkProof.cs so lanes
/// don't collide.
public static class SettingsFileWalkProof
{
    // App/Settings/SettingsNavigator.swift, SettingsRootView.swift, HermesKit/Settings/SettingsImportWords.swift (93f984bb1).
    public const string Footer = "Exported files leave out keys, tokens and passwords.";
    public const string ResetTitle = "Reset All Settings to Defaults?";
    public const string ResetMessage =
        "Every setting on the computer running Hermes goes back to its Hermes default. Keys, bots and chats stay. Export Settings\u2026 first to keep a copy.";
    public const string ResetAction = "Reset to Defaults";
    public const string ResetDone = "Settings reset to Hermes defaults.";
    public const string ImportFailedTitle = "Couldn\u2019t Import Settings";
    public const string NotASettingsFile = "That file isn\u2019t a Hermes settings file.";
    public const string ImportTitle = "Import Settings?";
    public const string ImportAction = "Import";
    public const string ImportedTitle = "Settings Imported";

    /// Every credential settings-gateway.py's record holds (ci/fixtures/settings_config_data.py): none may leave in a file
    /// or come back in a PUT.
    public static readonly IReadOnlyList<string> StandInSecrets =
    [
        "fixture-bearer-not-real-0000", "fixture-files-key-0000",
        "sk-fixture-openrouter-not-real-0000", "sk-ant-fixture-not-real-0000", "sk-or-fixture-not-real-0000",
    ];

    /// The walk's edit to its own export: Hermes' agent turn limit (one setting) set to this.
    public const long EditedMaxTurns = 77;

    private const string ConfigPut = "PUT /api/config";

    // [WIN-06a] Clear Model Favorites… (SettingsRootView.swift `settings.clear-models`, SettingsNavigator.swift
    // `confirmClearModels`, HermesKit/Settings/SettingsWords.swift `clearModelsMessage`, 93f984bb1).
    public const string ClearModels = "Clear Model Favorites\u2026";
    public const string ClearModelsTitle = "Clear Favorite & Recent Models?";
    public const string ClearModelsAction = "Clear";
    public const string ClearModelsDone = "Favorite and recent models cleared.";

    /// The section's buttons, in the Mac's order.
    public static readonly IReadOnlyList<string> Buttons =
        ["Export Settings\u2026", "Import Settings\u2026", ClearModels, "Reset to Defaults\u2026"];

    /// The buttons' words as shown, left to right: the Mac's four in its order.
    public static string? ButtonsRead(IReadOnlyList<string?> words) =>
        words.SequenceEqual(Buttons)
            ? null
            : $"the buttons read \u201C{string.Join(" | ", words.Select(w => w ?? "(nothing)"))}\u201D, not \u201C{string.Join(" | ", Buttons)}\u201D";

    /// Clear Favorite & Recent Models? for `favorites` stars and `recents` recents.
    public static string? ClearModelsConfirmReads(string? title, string? message, string? primary, string? close, int favorites, int recents)
    {
        static string Count(int n, string one, string many) => n == 1 ? "1 " + one : $"{n} {many}";
        var what = (favorites, recents) switch
        {
            (0, 0) => "No models are starred or recent on this device.",
            (_, 0) => $"Unstars {Count(favorites, "model", "models")}.",
            (0, _) => $"Forgets {Count(recents, "recent model", "recent models")}.",
            _ => $"Unstars {Count(favorites, "model", "models")} and forgets {Count(recents, "recent model", "recent models")}.",
        };
        return Reads(("title", title, ClearModelsTitle), ("message", message, what + " Bots, chats and each bot\u2019s default model stay."),
            ("action", primary, ClearModelsAction), ("cancel", close, "Cancel"));
    }

    /// Nothing of the settings' reached the stand-in after `mark`: no write of any kind, no request other than a GET,
    /// and no read of /api/config (the app's unrelated background GETs don't count).
    public static string? NoSettingsCall(JsonNode? state, double mark, string when)
    {
        var writes = (state.Arr("writes") ?? []).OfType<JsonNode>().Where(w => (w.Num("at") ?? 0) > mark).ToList();
        if (writes.Count > 0) return $"{when}: {writes.Count} write(s) reached the gateway ({writes[0].Str("method")})";
        foreach (var r in (state.Arr("rest") ?? []).OfType<JsonNode>().Where(r => (r.Num("at") ?? 0) > mark))
        {
            var (method, path) = (r.Str("method") ?? "", r.Str("path") ?? "");
            if (method != "GET") return $"{when}: {method} {path} reached the gateway";
            if (path.StartsWith("/api/config", StringComparison.Ordinal)) return $"{when}: the gateway's settings were read ({path})";
        }
        return null;
    }

    public static string? ResetConfirmReads(string? title, string? message, string? primary, string? close) =>
        Reads(("title", title, ResetTitle), ("message", message, ResetMessage), ("action", primary, ResetAction), ("cancel", close, "Cancel"));

    public static string? NotSettingsReads(string? title, string? message, string? close) =>
        Reads(("title", title, ImportFailedTitle), ("reason", message, NotASettingsFile), ("button", close, "OK"));

    /// The import's confirmation for one changed setting (`SettingsImportWords.confirmMessage(changes: 1)`).
    public static string? ImportConfirmReads(string? title, string? message, string? primary, string? close) =>
        Reads(("title", title, ImportTitle),
            ("message", message, "1 setting on your gateway will change to the file\u2019s values. Keys, tokens and passwords already there stay."),
            ("action", primary, ImportAction), ("cancel", close, "Cancel"));

    /// The HUD (`PagesHUD.show`) and the footer line after the one-setting import.
    public static string? ImportedReads(string? hudTitle, string? hudDetail, string? status) =>
        Reads(("HUD title", hudTitle, ImportedTitle), ("HUD detail", hudDetail, "1 setting changed."),
            ("status", status, "Settings imported. 1 setting changed."));

    private static string? Reads(params (string What, string? Is, string Should)[] parts)
    {
        foreach (var (what, isText, should) in parts)
            if (isText != should) return $"the {what} reads \u201C{isText ?? "(nothing)"}\u201D, not \u201C{should}\u201D";
        return null;
    }

    /// The Save As name: "Hermes settings <yyyy-MM-dd>.json" for `today`.
    public static string? ExportNamed(string? name, DateTime today)
    {
        var should = "Hermes settings " + today.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + ".json";
        return name == should ? null : $"the export is offered as \u201C{name}\u201D, not \u201C{should}\u201D";
    }

    /// The exported bytes: a JSON object holding none of the stand-in's credentials.
    public static string? ExportClean(byte[]? data)
    {
        if (data == null || data.Length == 0) return "the export handed over no bytes";
        string text;
        try { text = new UTF8Encoding(false, true).GetString(data); }
        catch (DecoderFallbackException) { return "the export isn't UTF-8"; }
        try { if (JsonNode.Parse(text) is not JsonObject) return "the export isn't a JSON object"; }
        catch (JsonException) { return "the export isn't JSON"; }
        foreach (var secret in StandInSecrets)
            if (text.Contains(secret, StringComparison.Ordinal)) return $"the export holds the stand-in's credential {secret}";
        return null;
    }

    /// The walk's own export with `agent.max_turns` set to EditedMaxTurns, and the one-setting patch an import of it
    /// must write. Throws when the export can't be edited or already holds that value (the import would prove nothing).
    public static (byte[] Edited, JsonObject Patch) Edit(byte[] export)
    {
        if (JsonNode.Parse(export) is not JsonObject file) throw new InvalidOperationException("the export isn't a JSON object");
        if (file["agent"] is not JsonObject agent) throw new InvalidOperationException("the export has no agent settings");
        if (agent["max_turns"] is JsonValue v && v.TryGetValue(out long now) && now == EditedMaxTurns)
            throw new InvalidOperationException($"agent.max_turns is already {EditedMaxTurns}");
        agent["max_turns"] = EditedMaxTurns;
        var edited = Encoding.UTF8.GetBytes(file.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return (edited, new JsonObject { ["agent"] = new JsonObject { ["max_turns"] = EditedMaxTurns } });
    }

    /// The newest `at` in the stand-in's record, writes and REST log alike (0 when empty): a mark taken before the walk
    /// acts, so only later calls are judged.
    public static double Mark(JsonNode? state) =>
        Math.Max(WalkProof.LastWriteAt(state), (state.Arr("rest") ?? []).OfType<JsonNode>().Select(r => r.Num("at") ?? 0).DefaultIfEmpty(0).Max());

    private static List<JsonNode> PutsAfter(JsonNode? state, double mark) =>
        [.. (state.Arr("writes") ?? []).OfType<JsonNode>().Where(w => (w.Num("at") ?? 0) > mark && w.Str("method") == ConfigPut)];

    /// No PUT /api/config after `mark` (`when`: what was done, for the words).
    public static string? NothingWritten(JsonNode? state, double mark, string when)
    {
        var puts = PutsAfter(state, mark);
        return puts.Count == 0 ? null : $"{when}: {puts.Count} PUT /api/config reached the gateway";
    }

    private static List<JsonNode> DefaultsReadsAfter(JsonNode? state, double mark) =>
        [.. (state.Arr("rest") ?? []).OfType<JsonNode>().Where(r => (r.Num("at") ?? 0) > mark && r.Str("method") == "GET"
            && (r.Str("path") ?? "").StartsWith("/api/config/defaults", StringComparison.Ordinal))];

    /// No GET /api/config/defaults after `mark`.
    public static string? NoDefaultsRead(JsonNode? state, double mark, string when) =>
        DefaultsReadsAfter(state, mark).Count == 0 ? null : $"{when}: the gateway's defaults were read";

    /// Exactly one PUT /api/config after `mark`, its body `{config: patch}` and no stand-in credential in it.
    public static string? ImportWritten(JsonNode? state, double mark, JsonObject patch)
    {
        var puts = PutsAfter(state, mark);
        if (puts.Count != 1) return $"the import sent {puts.Count} PUT /api/config, not 1";
        var config = puts[0]["params"].Get("config");
        var text = config?.ToJsonString() ?? "null";
        foreach (var secret in StandInSecrets)
            if (text.Contains(secret, StringComparison.Ordinal)) return $"the import wrote the credential {secret} back";
        return JsonNode.DeepEquals(config, patch) ? null : $"the import wrote {text}, not {patch.ToJsonString()}";
    }

    /// After `mark`: GET /api/config/defaults (Hermes' own, no ?profile), then exactly one PUT /api/config after it whose
    /// body is `{config: defaults}`.
    public static string? ResetWritten(JsonNode? state, double mark, JsonNode defaults)
    {
        var reads = DefaultsReadsAfter(state, mark);
        if (reads.Count == 0) return "the reset never read GET /api/config/defaults";
        if (reads.Any(r => (r.Str("path") ?? "") != "/api/config/defaults")) return $"the reset read {reads[0].Str("path")}, not /api/config/defaults";
        var puts = PutsAfter(state, mark);
        if (puts.Count != 1) return $"the reset sent {puts.Count} PUT /api/config, not 1";
        var firstRead = reads.Min(r => r.Num("at") ?? 0);
        if ((puts[0].Num("at") ?? 0) < firstRead) return "the reset wrote before it read the defaults";
        var config = puts[0]["params"].Get("config");
        return JsonNode.DeepEquals(config, defaults) ? null : $"the reset wrote {config?.ToJsonString() ?? "null"}, not Hermes' defaults";
    }
}
