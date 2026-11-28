using Hermes.Core.Settings;
using Hermes.Core.Shell;
using HermesHQ.Features.Settings;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-06] The CI's walk for Settings › About's Export Settings…, Import Settings… and Reset to Defaults… on the settings
/// stand-in (windows/ci/windows.yml), backed by `Hermes.Core.Shell.SettingsFileWalkProof` and settings-gateway.py's own
/// record:
///   settings-file  The About category page: the four buttons in the Mac's order and "Exported files leave out keys, tokens and passwords."
///                  Export: the file offered as "Hermes settings <today>.json" with none of the stand-in's (fake)
///                  credentials and nothing written. Import of a JSON array: "Couldn’t Import Settings" / "That file isn’t
///                  a Hermes settings file." and no PUT. Import of the walk's export with one setting edited: "Import
///                  Settings?" for 1 setting, Import, the "Settings Imported" HUD and exactly that one-setting PUT.
///                  [WIN-06a] Clear Model Favorites… with 2 seeded stars and 1 recent: "Clear Favorite & Recent
///                  Models?" in the Mac's words; Cancel keeps them; Clear empties them, "Favorite and recent models
///                  cleared.", and no settings call reaches the stand-in (the account's prior stars are put back after).
///                  Reset to Defaults…: the Mac's confirmation; Cancel reads and writes nothing; again and Reset to
///                  Defaults: GET /api/config/defaults, then one PUT of them, and "Settings reset to Hermes defaults."
///                  [WIN-06b] Search Settings "factory": Reset to Defaults…, About, first; its result asks as the button
///                  does, over About; Cancel reads and writes nothing. "backup" and Enter: Export Settings… runs again.
///                  [WIN-06d] "unstar": Clear Model Favorites…, About, first; its result asks Clear Model Favorites…'s
///                  question (not Reset's) for 1 synthetic star; Cancel keeps it, no settings call.
/// The OS Save As / Open pickers can't be driven on the runner, so for this walk alone SettingsFileUi's picker overrides
/// hand over files in the walk's temp folder (the dialogs are the real ContentDialogs, their buttons invoked through UI
/// Automation). Synthetic data only; the stand-in is reset afterwards by the reset itself.
internal static partial class ProofWalks
{
    private static void RegisterSettingsFileWalks() => Automation.NamedWalks["settings-file"] = SettingsFileAsync;

    private static async Task SettingsFileAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        if (SettingsFileUi.SaveOverride != null || SettingsFileUi.PickOverride != null) throw new InvalidOperationException("the pickers were already stood in for");
        var folder = Path.Combine(Path.GetTempPath(), "hq-settings-file-walk-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(folder);
        (string Name, byte[] Data)? saved = null;
        string? pickPath = null;
        SettingsFileUi.SaveOverride = async (name, data) =>
        {
            await File.WriteAllBytesAsync(Path.Combine(folder, "export.json"), data);
            saved = (name, data);
            return true;
        };
        SettingsFileUi.PickOverride = async () => pickPath == null ? null : new PickedSettingsFile(await File.ReadAllBytesAsync(pickPath));
        // [WIN-06a] The walk seeds and clears this account's model stars and recents: whatever was there before comes back.
        var store = HermesHQ.Features.Composer.ComposerServices.Store;
        var starKeys = client.AccountId is { } account
            ? new[] { Hermes.Core.Composer.ModelPrefs.FavoritesKey, Hermes.Core.Composer.ModelPrefs.RecentsKey }.Select(k => $"{k}|{account}").ToArray()
            : [];
        var before = starKeys.Select(store.Get).ToArray();
        try
        {
            await SettingsFileStepsAsync(shot, client, url, folder, () => saved, p => pickPath = p);
        }
        finally
        {
            for (var i = 0; i < starKeys.Length; i++) store.Set(starKeys[i], before[i]);
            SettingsFileUi.SaveOverride = null;
            SettingsFileUi.PickOverride = null;
            try { Directory.Delete(folder, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private static async Task SettingsFileStepsAsync(Func<string, Task> shot, Hermes.Core.HermesClient client, string url, string folder,
        Func<(string Name, byte[] Data)?> saved, Action<string> pick)
    {
        // Settings › Hermes (Backup & Reset in the 7-category layout, e27566897).
        Navigator.Open("settings");
        var page = await Until(() => SettingsPage.Current is { IsLoaded: true } p ? p : null, "Settings");
        AppLog.Note("automation", "walk settings-file: the Hermes category shown as its row's pick does");
        page.ShowCategory(SettingsCategory.Gateway);
        var export = await Until(() => Find("settings.export"), SettingsFileWords.Export);
        var import = Need("settings.import");
        var clearModels = Need("settings.clear-models");
        var reset = Need("settings.reset");
        // [WIN-06a] The Mac's four, in its order (left to right, then down when the row wraps).
        var inOrder = new[] { export, import, clearModels, reset }
            .OrderBy(b => Math.Round(b.TransformToVisual(Root).TransformPoint(default).Y)).ThenBy(b => b.TransformToVisual(Root).TransformPoint(default).X)
            .Select(ButtonWords).ToList();
        if (SettingsFileWalkProof.ButtonsRead(inOrder) is { } buttonWords) throw new InvalidOperationException(buttonWords);
        await Until(() => Shown(Root).OfType<TextBlock>().FirstOrDefault(t => t.Text == SettingsFileWalkProof.Footer), "the export footer");
        await Task.Delay(500);
        await shot("settings-file-buttons");

        // Export Settings…: the file handed to Save As.
        var mark = await StandInMarkAsync(url);
        Invoke(export);
        var got = await Until(() => saved() is { } s ? new Tuple<string, byte[]>(s.Name, s.Data) : null, "the exported file");
        var (name, data) = (got.Item1, got.Item2);
        if (SettingsFileWalkProof.ExportNamed(name, DateTime.Now) is { } named) throw new InvalidOperationException(named);
        if (SettingsFileWalkProof.ExportClean(data) is { } leaked) throw new InvalidOperationException(leaked);
        if (SettingsFileWalkProof.NothingWritten(await StandIn(url, "/__settings/state"), mark, "Export") is { } wroteOnExport)
            throw new InvalidOperationException(wroteOnExport);
        AppLog.Note("automation", $"walk settings-file: exported \u201C{name}\u201D, {data.Length} bytes, no stand-in credential");

        // Import Settings… with a JSON array: the Mac's alert, and nothing written.
        var notSettings = Path.Combine(folder, "not-settings.json");
        await File.WriteAllTextAsync(notSettings, "[\"not\", \"settings\"]");
        pick(notSettings);
        mark = await StandInMarkAsync(url);
        Invoke(import);
        var failed = await DialogAsync(SettingsFileWalkProof.ImportFailedTitle);
        if (SettingsFileWalkProof.NotSettingsReads(failed.Title as string, DialogText(failed), failed.CloseButtonText) is { } failWords)
            throw new InvalidOperationException(failWords);
        await shot("settings-file-not-settings");
        await DialogButtonAsync(failed, "CloseButton");
        await Task.Delay(800);
        if (SettingsFileWalkProof.NothingWritten(await StandIn(url, "/__settings/state"), mark, "a JSON array") is { } wroteOnArray)
            throw new InvalidOperationException(wroteOnArray);

        // Import Settings… with the export, one setting edited: asked for 1 setting, then exactly that written.
        var (edited, patch) = SettingsFileWalkProof.Edit(data);
        var editedPath = Path.Combine(folder, "edited.json");
        await File.WriteAllBytesAsync(editedPath, edited);
        pick(editedPath);
        mark = await StandInMarkAsync(url);
        Invoke(import);
        var confirm = await DialogAsync(SettingsFileWalkProof.ImportTitle);
        if (SettingsFileWalkProof.ImportConfirmReads(confirm.Title as string, DialogText(confirm), confirm.PrimaryButtonText, confirm.CloseButtonText) is { } confirmWords)
            throw new InvalidOperationException(confirmWords);
        if (SettingsFileWalkProof.NothingWritten(await StandIn(url, "/__settings/state"), mark, "before Import") is { } early)
            throw new InvalidOperationException(early);
        await DialogButtonAsync(confirm, "PrimaryButton");
        var hud = (InfoBar)await Until(() => Find("settings.import-done") is InfoBar { IsOpen: true } b ? b : null, "the Settings Imported HUD");
        await shot("settings-file-imported");
        var status = (TextBlock)Need("settings.file-status");
        if (SettingsFileWalkProof.ImportedReads(hud.Title, hud.Message, status.Text) is { } importedWords) throw new InvalidOperationException(importedWords);
        if (await RecordAsync(url, "/__settings/state", st => SettingsFileWalkProof.ImportWritten(st, mark, patch)) is { } importWire)
            throw new InvalidOperationException(importWire);

        // [WIN-06a] Clear Model Favorites…: this account's (synthetic) 2 stars and 1 recent; the Mac's confirmation; Cancel
        // keeps them; Clear empties them and says so; the gateway hears nothing either way.
        var models = client.AccountId is { } account ? HermesHQ.Features.Composer.ComposerServices.Prefs(account) : throw new InvalidOperationException("no account");
        models.SetFavorites(["nous::fixture-walk-model-a", "openrouter::fixture-walk-model-b"]);
        models.Remember(new Hermes.Core.Composer.ModelChoice("fixture-walk-model-c", "Fixture Walk C", "nous"));
        if (models.Favorites.Count != 2 || models.Recents.Count != 1)
            throw new InvalidOperationException($"seeded {models.Favorites.Count} stars and {models.Recents.Count} recents, not 2 and 1");
        mark = await StandInMarkAsync(url);
        Invoke(clearModels);
        var clearAsk = await DialogAsync(SettingsFileWalkProof.ClearModelsTitle);
        if (SettingsFileWalkProof.ClearModelsConfirmReads(clearAsk.Title as string, DialogText(clearAsk), clearAsk.PrimaryButtonText, clearAsk.CloseButtonText, 2, 1) is { } clearWords)
            throw new InvalidOperationException(clearWords);
        await shot("settings-file-clear-models-confirm");
        await DialogButtonAsync(clearAsk, "CloseButton");
        await Task.Delay(500);
        if (models.Favorites.Count != 2 || models.Recents.Count != 1) throw new InvalidOperationException("Cancel cleared the model stars or recents");
        Invoke(clearModels);
        var clearAgain = await DialogAsync(SettingsFileWalkProof.ClearModelsTitle);
        await DialogButtonAsync(clearAgain, "PrimaryButton");
        await Until(() => Find("settings.file-status") is TextBlock { Text: SettingsFileWalkProof.ClearModelsDone } s ? s : null, "\u201CFavorite and recent models cleared.\u201D");
        if (models.Favorites.Count != 0 || models.Recents.Count != 0)
            throw new InvalidOperationException($"Clear left {models.Favorites.Count} stars and {models.Recents.Count} recents");
        await Task.Delay(800);
        if (SettingsFileWalkProof.NoSettingsCall(await StandIn(url, "/__settings/state"), mark, "Clear Model Favorites") is { } clearWire)
            throw new InvalidOperationException(clearWire);
        AppLog.Note("automation", "walk settings-file: Clear Model Favorites asked for 2 stars and 1 recent, Cancel kept them, Clear emptied them, no gateway call");

        // Reset to Defaults…: the confirmation; Cancel reads and writes nothing.
        mark = await StandInMarkAsync(url);
        Invoke(reset);
        var ask = await DialogAsync(SettingsFileWalkProof.ResetTitle);
        if (SettingsFileWalkProof.ResetConfirmReads(ask.Title as string, DialogText(ask), ask.PrimaryButtonText, ask.CloseButtonText) is { } resetWords)
            throw new InvalidOperationException(resetWords);
        await shot("settings-file-reset-confirm");
        await DialogButtonAsync(ask, "CloseButton");
        await Task.Delay(1000);
        var cancelled = await StandIn(url, "/__settings/state");
        if ((SettingsFileWalkProof.NothingWritten(cancelled, mark, "Cancel") ?? SettingsFileWalkProof.NoDefaultsRead(cancelled, mark, "Cancel")) is { } onCancel)
            throw new InvalidOperationException(onCancel);

        // Again, and Reset to Defaults: Hermes' defaults read, then written once.
        Invoke(reset);
        var again = await DialogAsync(SettingsFileWalkProof.ResetTitle);
        await DialogButtonAsync(again, "PrimaryButton");
        await Until(() => Find("settings.file-status") is TextBlock { Text: SettingsFileWalkProof.ResetDone } s ? s : null, "\u201CSettings reset to Hermes defaults.\u201D");
        var defaults = await new GatewayConfigStore(new GatewayConfigApi(AppState.Client!.Session)).DefaultsAsync();
        if (await RecordAsync(url, "/__settings/state", st => SettingsFileWalkProof.ResetWritten(st, mark, defaults)) is { } resetWire)
            throw new InvalidOperationException(resetWire);
        await shot("settings-file-reset-done");

        // [WIN-06b] Search Settings finds the buttons (SettingsSearch.actions, context "About") and a result runs its
        // button's action over About (SettingsNavigator.open `.action`): "factory" → Reset to Defaults…, its confirmation;
        // Cancel reads and writes nothing. "backup" → Export Settings…, Enter on the results: the file offered again.
        var search = (TextBox)await Until(() => Find("settings.search"), "Search Settings");
        var resetHit = await SearchResultAsync(search, "factory", "search.action:reset");
        if (AutomationProperties.GetName(resetHit) != SettingsFileWords.Reset + ", Hermes")
            throw new InvalidOperationException($"the result reads {AutomationProperties.GetName(resetHit)}");
        await shot("settings-file-search");
        mark = await StandInMarkAsync(url);
        Invoke(resetHit);
        var fromSearch = await DialogAsync(SettingsFileWalkProof.ResetTitle);
        if (SettingsFileWalkProof.ResetConfirmReads(fromSearch.Title as string, DialogText(fromSearch), fromSearch.PrimaryButtonText, fromSearch.CloseButtonText) is { } searchWords)
            throw new InvalidOperationException(searchWords);
        if (Find("settings.reset") == null) throw new InvalidOperationException("Hermes's buttons aren't on show under the confirmation");
        await DialogButtonAsync(fromSearch, "CloseButton");
        await Task.Delay(1000);
        var searchCancelled = await StandIn(url, "/__settings/state");
        if ((SettingsFileWalkProof.NothingWritten(searchCancelled, mark, "Cancel from search") ?? SettingsFileWalkProof.NoDefaultsRead(searchCancelled, mark, "Cancel from search")) is { } onSearchCancel)
            throw new InvalidOperationException(onSearchCancel);
        // [WIN-06d] "unstar" → Clear Model Favorites…, Chat (SettingsSearch.swift e27566897); its result asks as the button
        // does (SettingsNavigator.swift:38), never Reset's confirmation; Cancel keeps the one synthetic star, no gateway call.
        models.SetFavorites(["nous::fixture-walk-model-a"]);
        var clearHit = await SearchResultAsync(search, "unstar", "search.action:clear-models");
        if (AutomationProperties.GetName(clearHit) != SettingsFileWords.ClearModels + ", Chat")
            throw new InvalidOperationException($"the result reads {AutomationProperties.GetName(clearHit)}");
        mark = await StandInMarkAsync(url);
        Invoke(clearHit);
        var clearFromSearch = await DialogAsync(SettingsFileWalkProof.ClearModelsTitle);
        if (SettingsFileWalkProof.ClearModelsConfirmReads(clearFromSearch.Title as string, DialogText(clearFromSearch), clearFromSearch.PrimaryButtonText, clearFromSearch.CloseButtonText, 1, 0) is { } clearSearchWords)
            throw new InvalidOperationException(clearSearchWords);
        if (Find("settings.clear-models") == null) throw new InvalidOperationException("Chat's Clear Model Favorites button isn't on show under the confirmation");
        await shot("settings-file-search-clear-models");
        await DialogButtonAsync(clearFromSearch, "CloseButton");
        await Task.Delay(500);
        if (models.Favorites.Count != 1) throw new InvalidOperationException("Cancel from search cleared the model star");
        if (SettingsFileWalkProof.NoSettingsCall(await StandIn(url, "/__settings/state"), mark, "Clear Model Favorites from search") is { } clearSearchWire)
            throw new InvalidOperationException(clearSearchWire);
        var before = saved();
        await SearchResultAsync(search, "backup", "search.action:export");
        search.Focus(FocusState.Keyboard);
        if (!await KeysAsync(() => Keys.Press(Keys.Enter), () => !Equals(saved(), before), "Enter on the results"))
            Invoke(Need("search.action:export"));
        var again2 = await Until(() => saved() is { } s && !Equals(s, before) ? new Tuple<string, byte[]>(s.Name, s.Data) : null, "the file exported from search");
        if (SettingsFileWalkProof.ExportNamed(again2.Item1, DateTime.Now) is { } named2) throw new InvalidOperationException(named2);
        if (SettingsFileWalkProof.ExportClean(again2.Item2) is { } leaked2) throw new InvalidOperationException(leaked2);
        AppLog.Note("automation", "walk settings-file: Search Settings found Reset to Defaults\u2026, Clear Model Favorites\u2026 and Export Settings\u2026 under About and ran them");
        await shot("settings-file");
    }

    /// Types `word` into Search Settings (keys, else its Text) and waits for the result row `id`, the first result.
    private static async Task<FrameworkElement> SearchResultAsync(TextBox search, string word, string id)
    {
        if (!Automation.AppOnly) Mouse.Click(search);
        if (FocusedIn() != search) search.Focus(FocusState.Keyboard);
        await Until(() => FocusedIn() == search ? search : null, "the caret in Search Settings");
        if (search.Text.Length > 0) search.Text = "";
        if (!await KeysAsync(() => Keys.Type(word), () => search.Text == word, $"typing {word}"))
        {
            search.Text = word;   // a WinUI TextBox's peer gives no managed Value pattern
            search.SelectionStart = search.Text.Length;
        }
        var hit = await Until(() => Find(id), $"{id} in the results");
        var first = Shown(Root).Select(Id).FirstOrDefault(i => i.StartsWith("search.", StringComparison.Ordinal));
        if (first != id) throw new InvalidOperationException($"the first result for {word} is {first}");
        return hit;
    }

    /// The newest moment in the stand-in's record (its writes and its REST log), so only later calls are judged.
    private static async Task<double> StandInMarkAsync(string url)
    {
        await Task.Delay(300);
        return SettingsFileWalkProof.Mark(await StandIn(url, "/__settings/state"));
    }

    /// A push button's words (its string Content, else the first text drawn in it).
    private static string? ButtonWords(FrameworkElement button) =>
        (button as Button)?.Content as string ?? Shown(button).OfType<TextBlock>().Select(t => t.Text).FirstOrDefault(t => !string.IsNullOrEmpty(t));

    /// The open ContentDialog titled `title` (15 s).
    private static Task<ContentDialog> DialogAsync(string title) =>
        Until(() => InPopups().OfType<ContentDialog>().FirstOrDefault(d => d.Title as string == title), $"\u201C{title}\u201D");

    private static string? DialogText(ContentDialog dialog) => dialog.Content switch
    {
        TextBlock t => t.Text,
        string s => s,
        _ => null,
    };

    /// A dialog's own button (its template's PrimaryButton / CloseButton) invoked through UI Automation, then the dialog gone.
    private static async Task DialogButtonAsync(ContentDialog dialog, string part)
    {
        var button = await Until(() => Shown(dialog).OfType<Button>().FirstOrDefault(b => b.Name == part), $"the dialog's {part}");
        Invoke(button);
        await Until(() => InPopups().OfType<ContentDialog>().All(d => d != dialog) ? Root : null, "the dialog to close");
    }
}
