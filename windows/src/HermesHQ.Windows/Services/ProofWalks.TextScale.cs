using Hermes.Core.Bots;
using Hermes.Core.Gateways;
using Hermes.Core.Shell;
using HermesHQ.Controls;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Gateways;
using HermesHQ.Features.Settings;
using HermesHQ.Features.Tasks;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;

namespace HermesHQ.Services;

/// [WIN-60] Larger text and high contrast, each in a second short app run of the CI (windows/ci/windows.yml, the step
/// after the screenshot walk) on its own pages stand-in, with the runner's Windows set first and put back after.
///
/// "text-scale": HKCU\Software\Microsoft\Accessibility TextScaleFactor = 150. UISettings.TextScaleFactor must be 1.5;
/// on Chats (the roster's first bot, its transcript and message box, the sidebar beside it), Tasks and the Settings
/// window every shown TextBlock cut short (IsTextTrimmed) is judged by Hermes.Core.Shell.TextScaleWalkProof: one-line
/// words cut where the Mac cuts them pass, running words a fixed size clips fail (the Mac wraps them). Each cut is
/// logged (area · key · lines · length, never its words). Then the sidebar's foot: the gateway's name cut in the middle
/// short of the gear (GatewayFootFit.Judge), at the kept width and at the narrowest open sidebar, where it is shot.
/// Pictures: text-scale-chat, -tasks, -settings, -foot.
///
/// "high-contrast": a contrast theme on (SystemParametersInfo SPI_SETHIGHCONTRAST, windows/ci/high-contrast.ps1). Windows
/// must say so (SPI_GETHIGHCONTRAST); every one of the app's own HQ* brushes must be in the HighContrast
/// theme dictionary in the theme's colour (HighContrastWalkProof.Palette). Text drawn in a colour that isn't one of the
/// theme's is logged per page as an open gap. Fills that carry words must be the theme's own pairs (Hermes.Core.Settings
/// ContrastTheme): your bubble on Chats, every view pill on Tasks, words without the backplate; any other is a failure.
/// Pictures: high-contrast-chat, -tasks, -settings.
internal static partial class ProofWalks
{
    private static void RegisterTextScaleWalks()
    {
        Automation.NamedWalks["text-scale"] = TextScaleAsync;
        Automation.NamedWalks["high-contrast"] = HighContrastAsync;
    }

    private static async Task TextScaleAsync(Func<string, Task> shot)
    {
        var factor = new UISettings().TextScaleFactor;
        AppLog.Note("automation", $"walk text-scale: UISettings.TextScaleFactor {factor:0.##}");
        if (TextScaleWalkProof.Scale(factor) is { } off) throw new InvalidOperationException(off);
        var cut = new List<CutText>();
        var visited = await ThreePagesAsync("text-scale", TextScaleWalkProof.Shots, shot, (page, roots) =>
        {
            var before = cut.Count;
            foreach (var (area, root) in roots)
                foreach (var t in Shown(root).OfType<TextBlock>())
                {
                    if (!t.IsTextTrimmed || t.ActualWidth <= 0) continue;
                    var found = new CutText(InTranscript(t, root) ? TextScaleWalkProof.Transcript : area, KeyOf(t),
                        t.TextWrapping != TextWrapping.NoWrap, t.MaxLines, t.Text?.Length ?? 0);
                    cut.Add(found);
                    AppLog.Note("automation", $"walk text-scale: {page} cut short: {found.Area} · {found.Key} · "
                        + $"{(found.Wraps ? "wraps" : "one line")}{(found.MaxLines > 0 ? $", {found.MaxLines} lines at most" : "")} · {found.Length} characters · "
                        + (TextScaleWalkProof.Judge(found) == null ? "the Mac cuts it too" : "the Mac wraps it"));
                }
            AppLog.Note("automation", $"walk text-scale: {page} {cut.Count - before} cut short");
        });
        var foot = await FootAtTextScaleAsync(shot);
        if (TextScaleWalkProof.Report(cut, visited) is { } wrong) throw new InvalidOperationException(foot == null ? wrong : wrong + "\n" + foot);
        if (foot != null) throw new InvalidOperationException(foot);
    }

    /// [WIN-FOOTER-GATEWAY-CLIP] The sidebar's foot at this text size: the gateway's name judged at the kept width, then at
    /// the narrowest open sidebar (its shot taken there), the width put back after. Null when both pass, else the findings.
    private static async Task<string?> FootAtTextScaleAsync(Func<string, Task> shot)
    {
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        var findings = new List<string>();
        void Judge(string at)
        {
            var host = shell.FootGateway;
            var foot = Shown(host).OfType<GatewayFoot>().FirstOrDefault() ?? throw new InvalidOperationException("the sidebar's foot has no gateway line");
            var name = Shown(foot).OfType<TextBlock>().FirstOrDefault(t => Id(t) == GatewayFoot.NameId)
                ?? throw new InvalidOperationException("the gateway's name isn't showing in the sidebar's foot");
            double X(FrameworkElement e, double x) => e.TransformToVisual(shell).TransformPoint(new Windows.Foundation.Point(x, 0)).X;
            var nameRight = X(name, name.ActualWidth);
            var roomRight = X(host, host.ActualWidth);
            var gearLeft = X(shell.FootSettingsButton, 0);
            var shown = name.Text ?? "";
            AppLog.Note("automation", $"walk text-scale: foot {at}: sidebar {shell.SidebarList.ActualWidth:0} wide, name {foot.WholeName.Length} characters shows {shown.Length}"
                + $"{(shown != foot.WholeName ? " (cut in the middle)" : "")}, {name.ActualWidth:0.#} wide, ends {roomRight - nameRight:0.#} inside its room and {gearLeft - nameRight:0.#} before the gear"
                + $"{(name.IsTextTrimmed ? ", cut at its end" : "")}");
            if (GatewayFootFit.Judge(foot.WholeName, shown, nameRight, roomRight, gearLeft, name.IsTextTrimmed) is { } wrong)
            {
                AppLog.Note("automation", $"walk text-scale: foot {at}: {wrong}");
                findings.Add($"{wrong} ({at})");
            }
        }

        Judge("at the kept width");
        shell.ShowOpenWidthForWalk(SidebarLayout.NarrowestOpen);
        try
        {
            await Task.Delay(800);   // laid out again
            Judge($"at the narrowest open sidebar ({SidebarLayout.NarrowestOpen:0})");
            await shot(TextScaleWalkProof.FootShot);
        }
        finally { shell.ShowOpenWidthForWalk(null); }
        return findings.Count == 0 ? null : string.Join("\n", findings);
    }

    private static async Task HighContrastAsync(Func<string, Task> shot)
    {
        var on = ThemeService.SystemHighContrast;
        AppLog.Note("automation", $"walk high-contrast: SPI_GETHIGHCONTRAST {on}");
        if (HighContrastWalkProof.On(on) is { } off) throw new InvalidOperationException(off);
        var system = new UISettings();
        var colours = Enum.GetValues<UIElementType>()
            .Where(e => HighContrastWalkProof.SystemColours.Contains(e.ToString()))
            .Select(e => Rgb(system.UIElementColor(e))).ToHashSet();
        AppLog.Note("automation", $"walk high-contrast: the theme's colours {string.Join(" ", colours.Select(c => $"#{c:X6}"))}");

        // The app's own brushes, as a page looks them up in code, each the theme's colour.
        var brushes = new List<string>();
        var resources = Application.Current.Resources;
        var contrast = resources.ThemeDictionaries.TryGetValue("HighContrast", out var d) ? d as ResourceDictionary : null;
        foreach (var (key, element) in HighContrastWalkProof.Palette)
        {
            var want = Rgb(system.UIElementColor(Enum.Parse<UIElementType>(element)));
            if (contrast == null || !contrast.TryGetValue(key, out var inTheme)) { brushes.Add($"{key} isn't in the HighContrast dictionary"); continue; }
            if (inTheme is not SolidColorBrush b || Rgb(b.Color) != want) brushes.Add($"{key} isn't {element} (#{want:X6}) there");
            try { _ = resources[key]; }
            catch (Exception e) { brushes.Add($"{key} can't be looked up: {e.GetType().Name}"); }
        }
        foreach (var wrong in brushes) AppLog.Note("automation", $"walk high-contrast: {wrong}");
        if (brushes.Count > 0) throw new InvalidOperationException($"{brushes.Count} of the app's brushes don't follow the contrast theme:\n" + string.Join("\n", brushes));

        var inks = new List<string>();
        // [WIN-CONTRAST-BUBBLE] Fills that carry words are the theme's own pairs (Hermes.Core.Settings.ContrastTheme):
        // your bubble on Chats, the picked pill and the others on Tasks, each one found and judged, or the walk fails.
        var named = Enum.GetValues<UIElementType>().Where(e => HighContrastWalkProof.SystemColours.Contains(e.ToString()))
            .ToDictionary(e => e.ToString(), e => Rgb(system.UIElementColor(e)));
        var fills = new List<string>();
        var visited = await ThreePagesAsync("high-contrast", HighContrastWalkProof.Shots, shot, (page, roots) =>
        {
            if (page == "Chats") fills.AddRange(UserBubbleFills(roots, named));
            if (page == "Tasks") fills.AddRange(PillFills(roots, named));
            var before = inks.Count;
            foreach (var (_, root) in roots)
                foreach (var t in Shown(root).OfType<TextBlock>())
                {
                    if (t.ActualWidth <= 0 || string.IsNullOrWhiteSpace(t.Text)) continue;
                    if (t.Foreground is SolidColorBrush f && HighContrastWalkProof.Ink(page, KeyOf(t), Rgb(f.Color), colours) is { } wrong) inks.Add(wrong);
                    foreach (var run in t.Inlines.OfType<Run>())
                        if (run.ReadLocalValue(TextElement.ForegroundProperty) != DependencyProperty.UnsetValue
                            && run.Foreground is SolidColorBrush rf && HighContrastWalkProof.Ink(page, KeyOf(t) + " (a run)", Rgb(rf.Color), colours) is { } wrongRun) inks.Add(wrongRun);
                }
            AppLog.Note("automation", $"walk high-contrast: {page} {inks.Count - before} in a colour of their own");
        });
        // Text in a colour of its own is an open gap, named one by one (it is judged from the shots), not a pass.
        foreach (var ink in inks.Distinct()) AppLog.Note("automation", $"walk high-contrast: open gap: {ink}");
        foreach (var wrong in fills) AppLog.Note("automation", $"walk high-contrast: {wrong}");
        if (fills.Count > 0) throw new InvalidOperationException($"{fills.Count} fill{(fills.Count == 1 ? "" : "s")} with words not in the contrast theme's pair:\n" + string.Join("\n", fills));
        if (HighContrastWalkProof.Report([], visited) is { } missed) throw new InvalidOperationException(missed);
    }

    /// Chats: your bubble (MessageView.UserBubbleName) with its words, Highlight under HighlightText, no backplate.
    /// None shown is a finding: the stand-in's chat opens with your message.
    private static List<string> UserBubbleFills((string Area, DependencyObject Root)[] roots, IReadOnlyDictionary<string, uint> named)
    {
        var found = new List<string>();
        var bubbles = roots.SelectMany(r => Shown(r.Root)).OfType<Border>()
            .Where(b => b.Name == MessageView.UserBubbleName && b.ActualWidth > 0).ToList();
        if (bubbles.Count == 0) return ["Chats · no bubble of yours shown"];
        foreach (var b in bubbles)
        {
            if (b.Child is not TextBlock words || words.Foreground is not SolidColorBrush ink || b.Background is not SolidColorBrush fill)
            {
                found.Add("Chats · your bubble isn't a solid fill under words");
                continue;
            }
            if (Hermes.Core.Settings.ContrastTheme.Judge("Chats · your bubble", Hermes.Core.Settings.ContrastTheme.Surface.UserBubble,
                    Rgb(fill.Color), Rgb(ink.Color), words.HighContrastAdjustment != ElementHighContrastAdjustment.None, named) is { } wrong)
                found.Add(wrong);
        }
        AppLog.Note("automation", $"walk high-contrast: Chats {bubbles.Count} bubble(s) of yours judged");
        return found;
    }

    /// Chats (the roster's first bot: the sidebar and the chat), Tasks and the Settings window, in that order; `judge` is
    /// handed each page's areas and roots once it is laid out, then its shot is taken. Hands back the pages visited.
    private static async Task<List<string>> ThreePagesAsync(string walk, string[] shots, Func<string, Task> shot,
        Action<string, (string Area, DependencyObject Root)[]> judge)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        var visited = new List<string>();

        var hub = await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Bots.Layout.Flat.Any() ? h : null, "the roster", 30);
        var first = hub.Bots.Layout.Flat.First().Id;
        var bot = hub.Bots.Bot(first) ?? throw new InvalidOperationException($"no bot {first}");
        Navigator.Go(new BotChatDestination(bot.Model));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } c && FindIn(c, "chat.composer") != null ? c : null, $"{first}'s chat with its composer", 20);
        var transcript = (ListView)Need(chat, "chat.transcript");
        for (var by = DateTime.UtcNow.AddSeconds(10); transcript.Items.Count == 0 && DateTime.UtcNow < by; await Task.Delay(200)) { }
        await Task.Delay(1000);
        var sidebar = shell.FindName("SidebarPane") as DependencyObject ?? throw new InvalidOperationException("the sidebar isn't showing");
        AppLog.Note("automation", $"walk {walk}: {first}'s chat shows {transcript.Items.Count} rows");
        judge("Chats", [(TextScaleWalkProof.Sidebar, sidebar), (TextScaleWalkProof.Chat, chat)]);
        visited.Add("Chats");
        await shot(shots[0]);
        if (walk == "text-scale") await LargeTextFindAsync(chat, transcript, shot);

        Navigator.Open("tasks");
        await Until(() => shell.WalkState() is { Pane: OpenPane.Place } f && f.PlaceId == "tasks" ? f : null, "Tasks in the main window", 20);
        await Until(() => Find(PageBar.TitleId("tasks")), "Tasks' title", 20);
        var tasks = await Until(() => Shown(Root).OfType<TasksPage>().FirstOrDefault(), "the Tasks page", 20);
        await Task.Delay(1500);   // its list is read and laid out
        judge("Tasks", [(TextScaleWalkProof.Tasks, tasks)]);
        visited.Add("Tasks");
        await shot(shots[1]);

        SettingsWindows.Show();
        var window = await Until(() => SettingsWindow.Showing, "the Settings window");
        await Until(() => window.Page is { IsLoaded: true } p ? p : null, "Settings in its window");
        await Until(() => FindIn((DependencyObject)window.Content, "settings.search"), "Search Settings in the window");
        await Task.Delay(1000);
        judge("Settings", [(TextScaleWalkProof.Settings, (DependencyObject)window.Content)]);
        visited.Add("Settings");
        await ShotOfAsync(window, () => shot(shots[2]));
        window.Close();
        await Until(() => SettingsWindow.OpenCount == 0 ? shell : null, "the Settings window to close");
        return visited;
    }

    /// Is `t` inside a message's row (a MessageView) under `root`?
    private static bool InTranscript(DependencyObject t, DependencyObject root)
    {
        for (var at = VisualTreeHelper.GetParent(t); at != null && !ReferenceEquals(at, root); at = VisualTreeHelper.GetParent(at))
            if (at is MessageView) return true;
        return false;
    }

    /// The text's own x:Name or automation id, else its nearest ancestor's.
    private static string KeyOf(DependencyObject t)
    {
        for (DependencyObject? at = t; at != null; at = VisualTreeHelper.GetParent(at))
        {
            if (at is FrameworkElement { Name.Length: > 0 } named) return named.Name;
            if (AutomationProperties.GetAutomationId(at) is { Length: > 0 } id) return id;
        }
        return "";
    }

    private static uint Rgb(Windows.UI.Color c) => ((uint)c.R << 16) | ((uint)c.G << 8) | c.B;
}
