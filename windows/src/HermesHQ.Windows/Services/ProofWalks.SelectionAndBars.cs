using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Settings;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-49] The CI's walk for the Mac's selection mark and page bars (windows/ci/windows.yml's "selection-and-bars" extra
/// on the pages stand-in), checked against Hermes.Core.Shell.DesktopLook (`SelectionAndBarsWalkProof`):
///   selection-and-bars           the roster's first bot opened, the window in front with the sidebar holding the focus:
///                                its row is marked, a box with no leading bar, the look's corner, 2 over and under, in
///                                the chosen-row accent at the Mac's share (App/Mac/MacSelection.swift).
///   selection-and-bars-sessions  Sessions' bar: the title in the page-title token, Filter · New Chat · Search, the
///                                magnifier at the trailing edge (MacWindow.pageBar, DesktopBars.searchToEdge).
///   selection-and-bars-tasks     Tasks' bar: the same title token, ⋯ · New Task · its search field at the edge.
///   selection-and-bars-jobs      [WIN-50] Jobs' bar: the title token, All Bots ⌄ · New Job · Search at the edge
///                                (JobRowView.swift `update(scope:)`; All Bots only with two bots or more, as the Mac).
///   selection-and-bars-kanban    [WIN-50] Kanban's bar: the title token, How Kanban Works · New Task · its search field
///                                at the edge (KanbanViewController.swift, DesktopBars.searchToEdge).
internal static partial class ProofWalks
{
    private static void RegisterSelectionAndBarsWalks()
    {
        Automation.NamedWalks["selection-and-bars"] = SelectionAndBarsAsync;
    }

    private static async Task SelectionAndBarsAsync(Func<string, Task> shot)
    {
        if (AppState.Client == null) throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        var desktop = ThemeService.State.DesktopLook;
        var hub = await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Bots.Layout.Flat.Any() ? h : null, "the roster", 30);
        var first = hub.Bots.Layout.Flat.First().Id;
        Navigator.Go(new BotChatDestination(hub.Bots.Bot(first)?.Model ?? throw new InvalidOperationException($"no bot {first}")));
        var row = await Until(() => shell.MarkedKey == "bot:" + first ? shell.MarkedRow : null, $"{first}'s row marked");

        // The window in front, the last click in the sidebar: the accent. Where the runner's desktop doesn't activate the
        // window, the shell is told so (the event a person's click raises) and the log says so.
        SelectionMark.SetFocus(DesktopLook.Pane.Sidebar);
        if (!SelectionMark.WindowActive)
        {
            AppLog.Note("automation", "walk selection-and-bars: the window wasn't active; marking it in front as its activation does");
            App.Window!.Activate();
            SelectionMark.SetWindowActive(true);
        }
        var tokens = ThemeService.Tokens;
        var c = SelectionMark.SelectedColor;
        var shown = new Hermes.Core.Settings.Rgba(c.R / 255.0, c.G / 255.0, c.B / 255.0, c.A / 255.0);
        if (SelectionAndBarsWalkProof.MarkFill(shown, tokens.ChosenRow, tokens.Label, ThemeService.Dark, emphasized: true) is { } fill)
            throw new InvalidOperationException(fill);
        var indicator = shell.SidebarResource("ListViewItemSelectionIndicatorVisualEnabled") is true;
        if (SelectionAndBarsWalkProof.MarkShape(indicator, row.CornerRadius.TopLeft, row.Margin.Top, row.Margin.Bottom, desktop) is { } shape)
            throw new InvalidOperationException(shape);
        // Off and on again: behind another window the mark is the grey, as a Mac's source list goes.
        SelectionMark.SetWindowActive(false);
        c = SelectionMark.SelectedColor;
        var behind = new Hermes.Core.Settings.Rgba(c.R / 255.0, c.G / 255.0, c.B / 255.0, c.A / 255.0);
        SelectionMark.SetWindowActive(true);
        if (SelectionAndBarsWalkProof.MarkFill(behind, tokens.ChosenRow, tokens.Label, ThemeService.Dark, emphasized: false) is { } grey)
            throw new InvalidOperationException(grey);
        AppLog.Note("automation", $"walk selection-and-bars: {first}'s row marked rgba({c.R},{c.G},{c.B},{c.A}) radius {row.CornerRadius.TopLeft}");
        await Task.Delay(400);
        await shot("selection-and-bars");

        await BarAsync("sessions", "Sessions", SelectionAndBarsWalkProof.SessionsBar, desktop);
        await shot("selection-and-bars-sessions");
        await BarAsync("tasks", "Tasks", SelectionAndBarsWalkProof.TasksBar, desktop);
        await shot("selection-and-bars-tasks");

        // [WIN-50] Jobs and Kanban, on the same stand-in. Jobs' All Bots leaves the bar with one bot (the Mac's too).
        Navigator.Open("jobs");
        await Until(() => Find("jobs.new"), "Jobs' New Job", 20);
        // The scope shows once the roster is read: up to 10 s for it, else the stand-in has one bot.
        var scoped = false;
        for (var deadline = DateTime.UtcNow.AddSeconds(10); DateTime.UtcNow < deadline && !scoped; await Task.Delay(200))
            scoped = Find("jobs.scope") != null;
        IReadOnlyList<string> jobs = scoped
            ? SelectionAndBarsWalkProof.JobsBar
            : SelectionAndBarsWalkProof.JobsBar.Where(id => id != "jobs.scope").ToArray();
        AppLog.Note("automation", $"walk selection-and-bars: Jobs' All Bots {(scoped ? "shows" : "is off (one bot)")}");
        await BarAsync("jobs", "Jobs", jobs, desktop);
        await shot("selection-and-bars-jobs");
        await BarAsync("kanban", "Kanban", SelectionAndBarsWalkProof.KanbanBar, desktop);
        await shot("selection-and-bars-kanban");
    }

    /// A page's bar: its title's size and weight, and its items read leading to trailing by where they sit.
    private static async Task BarAsync(string page, string name, IReadOnlyList<string> expected, bool desktop)
    {
        Navigator.Open(page);
        var title = (TextBlock)await Until(() => Find(PageBar.TitleId(page)) as TextBlock, $"{name}' title", 20);
        var items = await Until(() => expected.Select(Find).ToList() is var found && found.All(f => f != null) ? found! : null,
            $"{name}' bar items", 20);
        await Task.Delay(300);   // the bar lays out
        var root = Root;
        var order = expected.Zip(items, (id, e) => (id, x: e!.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point(0, 0)).X))
            .OrderBy(p => p.x).Select(p => p.id).ToList();
        if (SelectionAndBarsWalkProof.Bar(name, title.FontSize, title.FontWeight.Weight, order, expected, desktop) is { } wrong)
            throw new InvalidOperationException(wrong);
        AppLog.Note("automation", $"walk selection-and-bars: {name}' bar {title.FontSize} pt, {string.Join(" · ", order)}");
    }
}
