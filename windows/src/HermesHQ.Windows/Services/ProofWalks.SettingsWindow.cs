using Hermes.Core.Settings;
using Hermes.Core.Shell;
using HermesHQ.Features.Settings;
using HermesHQ.Features.Transcript;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-48] The CI's walk for Settings in a window of its own (windows/ci/windows.yml asks for it on the settings
/// stand-in), backed by the app's state (`Hermes.Core.Shell.SettingsWindowWalkProof`):
///   settings-window  The main window on Sessions. Ctrl+, opens the Settings window (titled Settings, one of it) on the
///                    category it was last left on, the main window still on Sessions; Ctrl+, again opens no second
///                    window and brings the one open forward. Another category picked in it (Enter on its row) shows
///                    and is marked. Ctrl+W in it closes it alone, the main window still on Sessions; opened again it
///                    shows the category it was closed on (MacSettingsWindow, KeyCommands.hqSettings / hqCloseChat).
/// Keys go in by SendInput; where they don't arrive, the walk calls what the key calls and says so in the app log.
internal static partial class ProofWalks
{
    private static void RegisterSettingsWindowWalks() => Automation.NamedWalks["settings-window"] = SettingsWindowAsync;

    private const ushort VkComma = 0xBC;

    private static async Task SettingsWindowAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        if (SettingsWindow.OpenCount > 0) throw new InvalidOperationException("a Settings window was already open");

        // The main window on Sessions, kept on show throughout.
        Navigator.Open("sessions");
        await Until(() => shell.WalkState() is { Pane: OpenPane.Place, PlaceId: "sessions" } f ? f : null, "Sessions in the main window");
        await Task.Delay(1000);
        var before = shell.WalkState();
        void MainAsItWas(string when)
        {
            if (SettingsWindowWalkProof.MainUnchanged(before, shell.WalkState(), Shown(Root).OfType<SettingsPage>().Any()) is { } changed)
                throw new InvalidOperationException($"{when}: {changed}");
        }
        var opening = SettingsWindowPlan.OpeningCategory(FilePreferences.Shared.Get(SettingsCategories.LastCategoryKey));

        // Ctrl+, in the main window: the Settings window opens on the category it was left on.
        FocusNeutral();
        if (!await KeysAsync(() => Keys.Press(VkComma, ctrl: true), () => SettingsWindow.Showing != null, "Ctrl+,"))
        {
            AppLog.Note("automation", "walk settings-window: Ctrl+, unproven by keyboard; calling what the key calls");
            SettingsWindows.Show();
        }
        var window = await Until(() => SettingsWindow.Showing, "the Settings window");
        var page = await Until(() => window.Page is { IsLoaded: true } p ? p : null, "Settings in its window");
        if (SettingsWindowWalkProof.OneWindow(SettingsWindow.OpenCount, window.Title) is { } one) throw new InvalidOperationException(one);
        await ShowsAsync(page, opening.Title());
        await Until(() => FindIn((DependencyObject)window.Content, "settings.search"), "Search Settings in the window");
        MainAsItWas("Ctrl+,");
        await ShotOfAsync(window, () => shot("settings-window"));

        // Ctrl+, again, from the main window: no second window; the open one comes forward.
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
        FocusNeutral();
        if (!await KeysAsync(() => Keys.Press(VkComma, ctrl: true), () => Foreground() == handle, "Ctrl+, again"))
        {
            AppLog.Note("automation", "walk settings-window: Ctrl+, again unproven by keyboard; calling what the key calls");
            SettingsWindows.Show();
        }
        if (SettingsWindowWalkProof.OneWindow(SettingsWindow.OpenCount, window.Title) is { } again) throw new InvalidOperationException($"Ctrl+, again: {again}");
        if (!ReferenceEquals(SettingsWindow.Showing, window)) throw new InvalidOperationException("Ctrl+, again replaced the Settings window");
        var forwardBy = DateTime.UtcNow.AddSeconds(10);
        while (Foreground() != handle && DateTime.UtcNow < forwardBy) await Task.Delay(100);
        AppLog.Note("automation", Foreground() == handle ? "walk settings-window: the Settings window came forward"
            : "walk settings-window: forward unproven (another process holds the foreground)");
        MainAsItWas("Ctrl+, again");

        // Another category, picked in the window by Enter on its row: its page shows and the column marks it.
        var pick = opening == SettingsCategory.Appearance ? SettingsCategory.Chat : SettingsCategory.Appearance;
        var row = await Until(() => Shown((DependencyObject)window.Content).OfType<ListViewItem>()
            .FirstOrDefault(i => i.Content is FrameworkElement fe && Id(fe) == "settings.category." + pick.Key()), $"{pick.Title()} in the column");
        window.Activate();
        row.Focus(FocusState.Keyboard);
        var picked = Foreground() == handle && Keys.Press(Keys.Enter, target: window);
        var pickedBy = DateTime.UtcNow.AddSeconds(10);
        while (picked && page.PageTitle != pick.Title() && DateTime.UtcNow < pickedBy) await Task.Delay(100);
        if (page.PageTitle == pick.Title()) AppLog.Note("automation", $"walk keys: Enter on {pick.Title()} by keyboard");
        else
        {
            AppLog.Note("automation", $"walk settings-window: Enter on {pick.Title()} unproven by keyboard; picking it as its row's click does");
            page.ShowCategory(pick);
        }
        await ShowsAsync(page, pick.Title());
        if (FilePreferences.Shared.Get(SettingsCategories.LastCategoryKey) != pick.Key())
            throw new InvalidOperationException($"{pick.Title()} isn't kept as the category to open on");
        MainAsItWas($"{pick.Title()} picked");
        await ShotOfAsync(window, () => shot("settings-window-section"));

        // Ctrl+W in the window: it closes alone; the main window is still on Sessions.
        var closed = false;
        window.Closed += (_, _) => closed = true;
        // Not KeysAsync: that brings the main window in front first, where Ctrl+W is its chat's Close Chat.
        var inFront = DateTime.UtcNow.AddSeconds(10);
        while (Foreground() != handle && DateTime.UtcNow < inFront) { window.Activate(); await Task.Delay(200); }
        if (Foreground() == handle && Keys.Press(Keys.W, ctrl: true, target: window))
        {
            var by = DateTime.UtcNow.AddSeconds(10);
            while (!closed && DateTime.UtcNow < by) await Task.Delay(100);
        }
        if (closed) AppLog.Note("automation", "walk keys: Ctrl+W in the Settings window by keyboard");
        else
        {
            AppLog.Note("automation", $"walk settings-window: Ctrl+W unproven by keyboard (foreground {(Foreground() == handle ? "it" : "another")}); closing it as the key does");
            window.Close();
        }
        await Until(() => closed && SettingsWindow.OpenCount == 0 ? shell : null, "the Settings window to close");
        MainAsItWas("Ctrl+W");

        // Opened again: on the category it was closed on. Then closed, so the next walk starts with none.
        SettingsWindows.Show();
        var reopened = await Until(() => SettingsWindow.Showing, "the Settings window again");
        if (ReferenceEquals(reopened, window)) throw new InvalidOperationException("the closed Settings window came back");
        await ShowsAsync(await Until(() => reopened.Page is { IsLoaded: true } p ? p : null, "Settings in its window again"), pick.Title());
        reopened.Close();
        await Until(() => SettingsWindow.OpenCount == 0 ? shell : null, "the Settings window to close again");
        MainAsItWas("the walk's end");
        Keys.Front();
    }

    /// The window's page reads `title` and its column marks it (10 s); otherwise what it shows.
    private static async Task ShowsAsync(SettingsPage page, string title)
    {
        var until = DateTime.UtcNow.AddSeconds(10);
        string? wrong;
        while ((wrong = SettingsWindowWalkProof.ShowsCategory(title, page.PageTitle, page.MarkedCategory)) != null && DateTime.UtcNow < until)
            await Task.Delay(100);
        if (wrong != null) throw new InvalidOperationException(wrong);
    }
}
