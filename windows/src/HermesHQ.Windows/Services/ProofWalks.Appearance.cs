using System.Runtime.ExceptionServices;
using Hermes.Core.Bots;
using Hermes.Core.Capabilities;
using Hermes.Core.Settings;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Capabilities;
using HermesHQ.Features.Settings;
using HermesHQ.Features.Transcript;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using SettingsWindow = HermesHQ.Features.Settings.SettingsWindow;

namespace HermesHQ.Services;

/// [WIN-APPEARANCE-WALK] The CI's walk through Settings › Appearance's newer pages (windows/ci/windows.yml asks for it on
/// the settings stand-in, whose bots, “Trip ideas” chat and skills the pages need), judged by
/// `Hermes.Core.Shell.AppearanceWalkProof`. It drives the app's own controls through their automation peers (no keys or
/// pointer from the OS):
///   appearance-pages                     Settings › Appearance in its window, as it opens (the iOS look).
///   appearance-chat-bubbles              Chat Bubbles: Corners set to 20 (the preview and the points follow; saved when
///                                        the slider lets go), Tinted on, the notes with Tinted's sentence.
///   appearance-chat-bubbles-desktop      The Desktop Look turned on by its switch: Chat Bubbles shows that look's own
///                                        Corners, no Tinted, the Desktop Look's note. Then turned off again.
///   appearance-density-compact-sidebar   Density › Compact: the sidebar's bot, chat and place rows at Compact's heights.
///   appearance-density-compact-sessions  Sessions' chat rows at Compact's height and padding.
///   appearance-sidebar-page              Settings › Appearance › Sidebar as it opens; Use Default Tabs shown only off the
///                                        default.
///   appearance-sidebar-moved             A place turned on under Add to Sidebar (it joins the places, and the sidebar),
///                                        then Move Up from its row's menu; Use Default Tabs appears. Then used.
///   capabilities-skills-oneline          Capabilities › Skills: each Installed row's line is one line, cut at its tail.
/// Before it ends, whatever it ends with, it puts back every preference it may have changed (the hqn.theme keys and the
/// Settings category) and the sidebar's own file, closes the Settings window, and checks they read as before.
/// Not here: the settled Q&A card with Answer Now (225c169d6) needs the questions stand-in's clarify history, which this
/// stand-in doesn't serve; QuestionsEndToEndTests cover it headless.
internal static partial class ProofWalks
{
    private static void RegisterAppearanceWalks() => Automation.NamedWalks["appearance-pages"] = AppearancePagesAsync;

    private static readonly FileDeviceStore SidebarDisk = new(ListsHub.DevicePath);

    private static List<PlaceInfo> PlaceInfos() => [.. Places.All.Select(p => new PlaceInfo(p.Id, p.Title, p.Section == Places.Tools))];

    private static async Task AppearancePagesAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        if (SettingsWindow.OpenCount > 0) throw new InvalidOperationException("a Settings window was already open");

        var prefs = AppearanceWalkProof.Snapshot(FilePreferences.Shared.Get, AppearanceWalkProof.PreferenceKeys);
        var sidebarFile = SidebarDisk.Read(AppearanceWalkProof.SidebarStoreKey);
        var wasFolded = Find(SidebarSearch.ToolsAutomationId) is not Grid;
        ExceptionDispatchInfo? failed = null;
        try { await AppearanceStepsAsync(shell, shot); }
        catch (Exception e) { failed = ExceptionDispatchInfo.Capture(e); }

        // Put back, whatever happened: the Settings window closed, the preferences and the sidebar's file as they were.
        string? notBack = null;
        try { notBack = await PutBackAsync(shell, prefs, sidebarFile, wasFolded); }
        catch (Exception e) when (failed != null) { AppLog.Note("automation", $"walk {AppearanceWalkProof.Walk}: putting back failed too: {e.Message}"); }
        failed?.Throw();
        if (notBack != null) throw new InvalidOperationException(notBack);
        AppLog.Note("automation", $"walk {AppearanceWalkProof.Walk}: every setting it changed is put back");
    }

    private static async Task AppearanceStepsAsync(ShellPage shell, Func<string, Task> shot)
    {
        // The sidebar open (Density's sizes are the open sidebar's; the rail keeps its own), by its fold button.
        if (Find(SidebarSearch.ToolsAutomationId) is not Grid) await UnfoldAsync(shell, fold: false);
        // The iOS look: Density and Tinted are its own.
        if (ThemeService.State.DesktopLook)
        {
            AppLog.Note("automation", $"walk {AppearanceWalkProof.Walk}: the Desktop Look was on; turned off for the walk (put back after)");
            ThemeService.SetDesktopLook(false);
        }

        // Settings › Appearance in its own window.
        SettingsWindows.Show();
        var window = await Until(() => SettingsWindow.Showing, "the Settings window");
        var page = await Until(() => window.Page is { IsLoaded: true } p ? p : null, "Settings in its window");
        DependencyObject Content() => (DependencyObject)window.Content;
        page.ShowCategory(SettingsCategory.Appearance);
        await Until(() => page.PageTitle == SettingsCategory.Appearance.Title() ? page : null, "Appearance in the Settings window");
        var row = await Until(() => FindIn(Content(), ChatBubbles.RowId), "the Chat Bubbles row");
        if (AppearanceWalkProof.BubblesRowReads(ThemeService.State, AutomationProperties.GetName(row)) is { } rowWrong) throw new InvalidOperationException(rowWrong);
        await Task.Delay(500);
        await ShotOfAsync(window, () => shot("appearance-pages"));

        // ---- Chat Bubbles (the iOS look): Corners to 20, Tinted on.
        Invoke(row);   // the row's own click (Kit.Nav), which pushes the page
        await BubblesPageAsync(page, Content);
        var slider = await Until(() => Shown(Content()).OfType<Slider>().FirstOrDefault(s => Id(s) == ChatBubbles.CornersId), "the Corners slider");
        Pattern<IRangeValueProvider>(slider, PatternInterface.RangeValue).SetValue(AppearanceWalkProof.WalkCorners);
        // Saved when the slider lets go: here, when it loses the keyboard (its LostFocus), as a pointer's release does.
        slider.Focus(FocusState.Programmatic);
        await Task.Delay(200);
        FocusNeutral();
        if (!await WaitAsync(() => ThemeService.State.BubbleCorners == AppearanceWalkProof.WalkCorners))
        {
            AppLog.Note("automation", $"walk {AppearanceWalkProof.Walk}: Corners not saved on the slider's let-go; saving it as the let-go does");
            ThemeService.SetBubbleCorners(AppearanceWalkProof.WalkCorners);
        }
        await CornersAsync(Content, AppearanceWalkProof.WalkCorners);
        var tinted = await Until(() => Shown(Content()).OfType<ToggleSwitch>().FirstOrDefault(t => Id(t) == ChatBubbles.TintedId), "the Tinted switch");
        if (!tinted.IsOn) Pattern<IToggleProvider>(tinted, PatternInterface.Toggle).Toggle();
        if (!await WaitAsync(() => ThemeService.State.BubbleStyle == BubbleStyle.Tinted))
            throw new InvalidOperationException("Tinted turned on saved no Tinted style");
        if (AppearanceWalkProof.BubblesSaved(ThemeService.State, AppearanceWalkProof.WalkCorners, BubbleStyle.Tinted) is { } saved) throw new InvalidOperationException(saved);
        await BubblesPageAsync(page, Content);
        await CornersAsync(Content, AppearanceWalkProof.WalkCorners);
        await Task.Delay(500);
        await ShotOfAsync(window, () => shot("appearance-chat-bubbles"));

        // ---- The Desktop Look, by its switch on Appearance: Chat Bubbles is that look's own Corners.
        await DesktopLookAsync(page, Content, on: true);
        page.Open(ChatBubbles.Target);
        await BubblesPageAsync(page, Content);
        await CornersAsync(Content, ThemeService.State.DesktopCorners);
        await Task.Delay(500);
        await ShotOfAsync(window, () => shot("appearance-chat-bubbles-desktop"));
        await DesktopLookAsync(page, Content, on: false);

        // ---- Density › Compact (the iOS look's), by its segment on Appearance.
        var compact = await Until(() => Shown(Content()).OfType<ToggleButton>().FirstOrDefault(b => Id(b) == $"{DensityRow.AutomationId}.{ListDensity.Compact.Raw()}"), "Density's Compact");
        if (FrameworkElementAutomationPeer.CreatePeerForElement(compact) is IToggleProvider press && compact.IsChecked != true) press.Toggle();
        if (!await WaitAsync(() => ThemeService.State.Density == ListDensity.Compact))
        {
            // A ToggleButton's automation Toggle doesn't raise its Click, where the segment saves.
            AppLog.Note("automation", $"walk {AppearanceWalkProof.Walk}: Compact's segment toggled without its click; picking Compact as its click does");
            ThemeService.SetDensity(ListDensity.Compact);
        }
        if (!ThemeService.State.Compact) throw new InvalidOperationException("Compact picked, but the lists don't draw Compact");
        var sidebarSizes = DensitySizes.Sidebar(compact: true);
        await ProvenAsync(() => AppearanceWalkProof.SidebarRowsAt(SidebarRows(shell), sidebarSizes), 10);
        await Task.Delay(500);
        await shot("appearance-density-compact-sidebar");
        Navigator.Open("sessions");
        await Until(() => shell.WalkState() is { Pane: OpenPane.Place, PlaceId: "sessions" } f ? f : null, "Sessions in the main window", 20);
        var sessionSizes = DensitySizes.Sessions(compact: true);
        await ProvenAsync(() => AppearanceWalkProof.SessionRowsAt(SessionRows(), sessionSizes), 20);
        await Task.Delay(500);
        await shot("appearance-density-compact-sessions");

        // ---- Settings › Appearance › Sidebar: a place turned on, Move Up, Use Default Tabs.
        var infos = PlaceInfos();
        page.Open(SidebarPage.Target);
        await Until(() => page.PageTitle == SidebarPage.Title ? page : null, "the Sidebar page");
        var start = SidebarLayout.Load(SidebarDisk);
        var shown = start.Shown(infos);
        await ProvenAsync(() => SidebarPageReads(Content(), shown, start.IsDefault(infos)), 10);
        await Task.Delay(500);
        await ShotOfAsync(window, () => shot("appearance-sidebar-page"));

        var add = start.AddRows(infos).FirstOrDefault() ?? throw new InvalidOperationException("Add to Sidebar has no place to turn on");
        var addSwitch = await Until(() => Shown(Content()).OfType<ToggleSwitch>().FirstOrDefault(t => Id(t) == SidebarPage.RowAutomationId(add.Id) && !t.IsOn), $"{add.Title}'s switch under {SidebarPage.AddHeader}");
        Pattern<IToggleProvider>(addSwitch, PatternInterface.Toggle).Toggle();
        await ProvenAsync(() => AppearanceWalkProof.Added(shown, SidebarLayout.Load(SidebarDisk).Shown(infos), add.Id), 10);
        var added = SidebarLayout.Load(SidebarDisk).Shown(infos);
        await ProvenAsync(() => WalkProof.Order(SidebarPlaces(shell), added, "the sidebar's places"), 10);

        // Move Up from the row's own menu (the keyboard's way to move it, as the drag does).
        var item = await Until(() => Shown(Content()).OfType<ListViewItem>().FirstOrDefault(i => i.Tag as string == add.Id), $"{add.Title}'s row under {SidebarPage.ShownHeader}");
        var menu = item.ContextFlyout as MenuFlyout ?? throw new InvalidOperationException($"{add.Title}'s row has no menu");
        menu.ShowAt(item);
        // The menu opens in the Settings window, whose popups are its own XamlRoot's, not the main window's.
        var moveUp = await Until(() => MenuItemIn(item.XamlRoot, "Move Up"), "Move Up in the row's menu");
        if (!moveUp.IsEnabled) throw new InvalidOperationException($"Move Up is off for {add.Title}");
        Invoke(moveUp);
        menu.Hide();
        await ProvenAsync(() => AppearanceWalkProof.MovedUp(added, SidebarLayout.Load(SidebarDisk).Shown(infos), add.Id), 10);
        var moved = SidebarLayout.Load(SidebarDisk);
        await ProvenAsync(() => WalkProof.Order(SidebarPlaces(shell), moved.Shown(infos), "the sidebar's places after Move Up"), 10);
        await ProvenAsync(() => SidebarPageReads(Content(), moved.Shown(infos), moved.IsDefault(infos)), 10);
        await Task.Delay(500);
        await ShotOfAsync(window, () => shot("appearance-sidebar-moved"));

        // Use Default Tabs: the default places, and the button gone.
        var reset = await Until(() => FindIn(Content(), SidebarPage.UseDefaultId), SidebarPage.UseDefault);
        Invoke(reset);
        await ProvenAsync(() => SidebarLayout.Load(SidebarDisk).IsDefault(infos) ? null : $"{SidebarPage.UseDefault} left the places changed", 10);
        await ProvenAsync(() => AppearanceWalkProof.UseDefaultShown(true, FindIn(Content(), SidebarPage.UseDefaultId) != null), 10);

        // ---- Capabilities › Skills: one-line rows.
        Navigator.Open("capabilities", new CapabilitiesTarget(CapabilitiesTab.Skills));
        var lines = CapabilitiesWords.SkillLineLines(TextScale());
        await ProvenAsync(() => AppearanceWalkProof.SkillRowsOneLine(SkillRows(), AppearanceWalkProof.StandInSkills, lines), 20);
        await Task.Delay(500);
        await shot("capabilities-skills-oneline");
    }

    /// The open menu's item reading `text` among one window's popups (MenuItem reads the main window's only).
    private static MenuFlyoutItem? MenuItemIn(XamlRoot? root, string text) =>
        root is null ? null : Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(root)
            .Where(p => p.Child != null).SelectMany(p => Shown(p.Child)).OfType<MenuFlyoutItem>().FirstOrDefault(i => i.Text == text);

    /// The Settings window closed, the preferences and the sidebar's file written back as they were read, the theme and
    /// the sidebar redrawn from them, and the sidebar folded again if it was. Null when every one reads as before.
    private static async Task<string?> PutBackAsync(ShellPage shell, IReadOnlyDictionary<string, string?> prefs, string? sidebarFile, bool wasFolded)
    {
        if (SettingsWindow.Showing is { } open)
        {
            open.Close();
            await Until(() => SettingsWindow.OpenCount == 0 ? shell : null, "the Settings window to close");
        }
        foreach (var (key, value) in prefs) FilePreferences.Shared.Set(key, value);
        // ThemeService reads the store again on a change: one that writes what is already there (Density as stored, or
        // its default when unset), then the raw values once more in case it wrote a default where nothing was kept.
        ThemeService.SetDensity(ThemeService.Store.Load().Density);
        foreach (var (key, value) in prefs) FilePreferences.Shared.Set(key, value);
        SidebarDisk.Write(AppearanceWalkProof.SidebarStoreKey, sidebarFile);
        SidebarLayout.NotifyChanged();
        if (wasFolded && Find(SidebarSearch.ToolsAutomationId) is Grid) await UnfoldAsync(shell, fold: true);
        var stored = new Dictionary<string, string?>(prefs) { ["\u0001sidebar"] = sidebarFile };
        return AppearanceWalkProof.Restored(stored, k => k == "\u0001sidebar" ? SidebarDisk.Read(AppearanceWalkProof.SidebarStoreKey) : FilePreferences.Shared.Get(k));
    }

    /// The sidebar folded or opened by its fold button's own click (its automation Invoke).
    private static async Task UnfoldAsync(ShellPage shell, bool fold)
    {
        Invoke((FrameworkElement)(shell.FindName("FoldButton") ?? throw new InvalidOperationException("no FoldButton")));
        await Until(() => (fold ? Find(SidebarSearch.ToolsAutomationId) is StackPanel : Find(SidebarSearch.ToolsAutomationId) is Grid) ? shell : null,
            fold ? "the sidebar folded" : "the sidebar open");
    }

    /// The Desktop Look's switch on Appearance (`row:desktop-look`), flipped by its toggle pattern.
    private static async Task DesktopLookAsync(SettingsPage page, Func<DependencyObject> content, bool on)
    {
        page.ShowCategory(SettingsCategory.Appearance);
        var toggle = await Until(() => Shown(content()).OfType<ToggleSwitch>().FirstOrDefault(t => Id(t) == "row:desktop-look"), "the Desktop Look's switch");
        if (toggle.IsOn != on) Pattern<IToggleProvider>(toggle, PatternInterface.Toggle).Toggle();
        if (!await WaitAsync(() => ThemeService.State.DesktopLook == on)) throw new InvalidOperationException($"the Desktop Look's switch left the look {(on ? "off" : "on")}");
        await Until(() => FindIn(content(), ChatBubbles.RowId), "the Chat Bubbles row after the Desktop Look's switch");
        if (AppearanceWalkProof.BubblesRowReads(ThemeService.State, AutomationProperties.GetName(Need(content(), ChatBubbles.RowId))) is { } wrong)
            throw new InvalidOperationException(wrong);
    }

    /// The Chat Bubbles page on show and as it should be for the look in use.
    private static async Task BubblesPageAsync(SettingsPage page, Func<DependencyObject> content)
    {
        await Until(() => page.PageTitle == ChatBubbles.Label && FindIn(content(), ChatBubbles.PageId) != null ? page : null, "the Chat Bubbles page");
        await ProvenAsync(() =>
        {
            var at = FindIn(content(), ChatBubbles.PageId)!;
            var tinted = Shown(at).OfType<ToggleSwitch>().FirstOrDefault(t => Id(t) == ChatBubbles.TintedId);
            var texts = Shown(at).OfType<TextBlock>().Select(t => t.Text).ToList();
            return AppearanceWalkProof.BubblesPage(ThemeService.State, tinted != null, tinted?.IsOn == true, texts);
        }, 10);
    }

    /// Corners on the page reads `points`: its value, the preview's message and the slider.
    private static Task CornersAsync(Func<DependencyObject> content, int points) => ProvenAsync(() =>
    {
        if (Shown(content()).OfType<StackPanel>().FirstOrDefault(s => s.Tag as string == ChatBubbles.CornersId) is not { } row) return "no Corners row";
        var value = Shown(row).OfType<TextBlock>().Select(t => t.Text).FirstOrDefault(t => t.EndsWith(" pt", StringComparison.Ordinal));
        var preview = Shown(row).OfType<Border>().FirstOrDefault(b => b.Child is TextBlock { Text: "Thanks!" });
        var slider = Shown(row).OfType<Slider>().FirstOrDefault();
        if (preview == null || slider == null) return "the Corners row has no preview or no slider";
        return AppearanceWalkProof.CornersShown(points, value, preview.CornerRadius.TopLeft, slider.Value, AutomationProperties.GetItemStatus(slider));
    }, 10);

    /// The Sidebar page's places in its Sidebar list are `shown` in order, and Use Default Tabs shows only off the default.
    private static string? SidebarPageReads(DependencyObject content, IReadOnlyList<string> shown, bool isDefault)
    {
        var rows = Shown(content).OfType<ListViewItem>().Select(i => i.Tag as string).OfType<string>().ToList();
        return WalkProof.Order(rows, shown, $"the {SidebarPage.Title} page's places")
            ?? AppearanceWalkProof.UseDefaultShown(isDefault, FindIn(content, SidebarPage.UseDefaultId) != null);
    }

    /// The open sidebar's rows by kind, with the height each is drawn at least.
    private static List<(AppearanceWalkProof.SidebarRow, double)> SidebarRows(ShellPage shell) =>
        [.. (shell.SidebarList.ItemsSource as IEnumerable<object> ?? []).OfType<ListViewItem>().Select(i => (i.Tag switch
        {
            SidebarBot => AppearanceWalkProof.SidebarRow.Bot,
            SidebarRoom => AppearanceWalkProof.SidebarRow.Room,
            SidebarChat => AppearanceWalkProof.SidebarRow.Chat,
            SidebarPlace => AppearanceWalkProof.SidebarRow.Place,
            _ => AppearanceWalkProof.SidebarRow.Other,
            // The row's pitch: SidebarItems.Make takes the selection mark's inset (SelectionMark.Shape's margin, 2 over
            // and under) off MinHeight so rows keep their pitch; CI run 45077678499 read 22 for Compact's 26 without it.
        }, i.MinHeight + i.Margin.Top + i.Margin.Bottom))];

    /// The sidebar's places above Tools, in order.
    private static List<string> SidebarPlaces(ShellPage shell) =>
        [.. (shell.SidebarList.ItemsSource as IEnumerable<object> ?? []).OfType<ListViewItem>().Select(i => i.Tag).OfType<SidebarPlace>().Where(p => !p.IsTool).Select(p => p.Place.Id)];

    /// Sessions' chat rows (SessionsPage's own ChatRow tag): their height and the room over their words.
    private static List<(double, double)> SessionRows()
    {
        if (Shown(Root).OfType<SessionsPage>().FirstOrDefault() is not { } sessions || sessions.FindName("SessionList") is not ListView list) return [];
        return [.. (list.ItemsSource as IEnumerable<object> ?? []).OfType<ListViewItem>().Where(i => i.Tag?.GetType().Name == "ChatRow")
            .Select(i => (i.MinHeight, (i.Content as Grid)?.Padding.Top ?? double.NaN))];
    }

    /// Capabilities › Skills' Installed rows: each row's skill, and how its line under the name is drawn.
    private static List<(string, int, bool)> SkillRows()
    {
        var found = new List<(string, int, bool)>();
        foreach (var row in Shown(Root).Where(e => Id(e).StartsWith("skill-row-", StringComparison.Ordinal)))
        {
            // Kit.Row's words: the name (14) then the line (12), which is the one cut to its lines.
            var line = Shown(row).OfType<TextBlock>().FirstOrDefault(t => t.FontSize == 12 && t.Text.Length > 0);
            if (line == null) continue;
            found.Add((Id(row)["skill-row-".Length..], line.MaxLines, line.TextTrimming == TextTrimming.CharacterEllipsis));
        }
        return found;
    }

    /// Windows' text size, as Capabilities reads it when it draws the rows.
    private static double TextScale()
    {
        try { return new Windows.UI.ViewManagement.UISettings().TextScaleFactor; }
        catch { return 1; }
    }

    /// True once `done` holds, within 10 s.
    private static async Task<bool> WaitAsync(Func<bool> done)
    {
        var until = DateTime.UtcNow.AddSeconds(10);
        while (!done() && DateTime.UtcNow < until) await Task.Delay(100);
        return done();
    }

    /// Waits (never under 10 s) for `check` to answer null; otherwise throws its last answer.
    private static async Task ProvenAsync(Func<string?> check, int seconds)
    {
        var until = DateTime.UtcNow.AddSeconds(Math.Max(10, seconds));
        string? wrong;
        while ((wrong = check()) != null && DateTime.UtcNow < until) await Task.Delay(200);
        if (wrong != null) throw new InvalidOperationException(wrong);
    }
}
