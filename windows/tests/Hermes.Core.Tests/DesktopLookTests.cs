using Hermes.Core.Settings;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// [WIN-49] The Mac's selection mark (App/Mac/MacSelection.swift, App/Theme/DesktopLayout.swift `DesktopRows`) and page
/// bar (App/Mac/MacWindow.swift `pageBar`, App/Kit/PageBarCapsule.swift, App/Theme/DesktopBars.swift) as numbers, and the
/// walk's checks on them, including the Windows shell as it drew them before (a leading bar, a 22 % fill, a 20 pt title,
/// Sessions' magnifier between Filter and New Chat).
public class DesktopLookTests
{
    static readonly Rgba Tint = Rgba.Hex(0x3478F6);
    static readonly Rgba LabelLight = Rgba.Hex(0x000000);
    static readonly Rgba LabelDark = Rgba.Hex(0xFFFFFF);

    [Fact]
    public void TheMarkIsAnInsetRoundedBoxWithNoLeadingBar()
    {
        Assert.Equal(2, DesktopLook.MarkInsetTop);
        Assert.Equal(8, DesktopLook.MarkInsetSide);
        Assert.Equal(2, DesktopLook.MarkInsetBottom);
        Assert.Equal(4, DesktopLook.MarkRadius(desktopLook: true));
        Assert.Equal(8, DesktopLook.MarkRadius(desktopLook: false));
        Assert.False(DesktopLook.LeadingIndicator);
        Assert.Null(SelectionAndBarsWalkProof.MarkShape(false, 4, 2, 2, desktopLook: true));
        // WinUI's own ListViewItem: a leading pill, and its 4 pt corner in the iOS look.
        Assert.Contains("leading accent bar", SelectionAndBarsWalkProof.MarkShape(true, 4, 2, 2, true));
        Assert.Contains("corner", SelectionAndBarsWalkProof.MarkShape(false, 4, 2, 2, desktopLook: false));
        Assert.Contains("inset", SelectionAndBarsWalkProof.MarkShape(false, 4, 0, 0, true));
    }

    [Fact]
    public void TheMarksColoursAreTheMacs()
    {
        Assert.Equal(0.24, DesktopLook.Accent(Tint, dark: false).A, 3);
        Assert.Equal(0.42, DesktopLook.Accent(Tint, dark: true).A, 3);
        Assert.Equal(Tint.R, DesktopLook.Accent(Tint, false).R, 6);
        // An ink tint (near-white, no hue) in dark: a fifth.
        Assert.True(DesktopLook.InkTint(Rgba.Hex(0xF2F2F2)));
        Assert.False(DesktopLook.InkTint(Tint));
        Assert.False(DesktopLook.InkTint(Rgba.Hex(0x808080)));   // Paper's mid grey keeps 42 %
        Assert.Equal(0.2, DesktopLook.Accent(Rgba.Hex(0xF2F2F2), dark: true).A, 3);
        Assert.Equal(0.24, DesktopLook.Accent(Rgba.Hex(0xF2F2F2), dark: false).A, 3);
        Assert.Equal(0.09, DesktopLook.Grey(LabelLight, dark: false).A, 3);
        Assert.Equal(0.14, DesktopLook.Grey(LabelDark, dark: true).A, 3);
    }

    [Fact]
    public void TheAccentIsForTheFocusedPaneOfTheFrontWindowAndAPressIsGrey()
    {
        var S = DesktopLook.Pane.Sidebar; var L = DesktopLook.Pane.List;
        Assert.Equal(DesktopLook.Pane.Sidebar, DesktopLook.FirstFocus);
        Assert.Equal(DesktopLook.Mark.Accent, DesktopLook.Fill(true, false, S, S, windowActive: true));
        Assert.Equal(DesktopLook.Mark.Grey, DesktopLook.Fill(true, false, S, S, windowActive: false));
        Assert.Equal(DesktopLook.Mark.Grey, DesktopLook.Fill(true, false, S, L, windowActive: true));
        Assert.Equal(DesktopLook.Mark.Grey, DesktopLook.Fill(false, true, S, S, true));
        Assert.Equal(DesktopLook.Mark.None, DesktopLook.Fill(false, false, S, S, true));
    }

    [Fact]
    public void TheWalkTellsTheMacsFillFromWindowsOldOne()
    {
        Assert.Null(SelectionAndBarsWalkProof.MarkFill(Tint.Alpha(0.24), Tint, LabelLight, dark: false, emphasized: true));
        Assert.Null(SelectionAndBarsWalkProof.MarkFill(LabelLight.Alpha(0.09), Tint, LabelLight, dark: false, emphasized: false));
        // The shell's old HQChosenRowBrush: the chosen row at 22 %.
        Assert.Contains("accent", SelectionAndBarsWalkProof.MarkFill(Tint.Alpha(0.22), Tint, LabelLight, false, true));
        Assert.Contains("grey", SelectionAndBarsWalkProof.MarkFill(Tint.Alpha(0.24), Tint, LabelLight, false, false));
    }

    [Fact]
    public void ThePageBarIsTheMacs()
    {
        Assert.Equal(15, DesktopLook.PageTitleSize(desktopLook: true));
        Assert.Equal(17, DesktopLook.PageTitleSize(desktopLook: false));
        Assert.Equal(600, DesktopLook.PageTitleWeight);
        Assert.Equal(12.5, DesktopLook.PageSubtitleSize(true));
        Assert.Equal(13, DesktopLook.PageSubtitleSize(false));
        Assert.False(DesktopLook.BarHairline);
        Assert.Equal(15, DesktopLook.BarGlyph);
        Assert.Equal(44, DesktopLook.BarItem);
        Assert.Equal(6, DesktopLook.BarItemGlyphSide);
        Assert.Equal(20, DesktopLook.PageSide);
        Assert.Equal(5.5, DesktopLook.BarTrailingPad);
        Assert.Equal(50, DesktopLook.BarHeight);
    }

    [Fact]
    public void TheMagnifierGoesToTheTrailingEdge()
    {
        Assert.Equal(["sessions.filter", "sessions.compose", "sessions.search"],
            DesktopLook.BarOrder(["sessions.filter", "sessions.search", "sessions.compose"]));
        Assert.Equal(["jobs.filter", "jobs.search"], DesktopLook.BarOrder(["jobs.filter", "jobs.search"]));
        Assert.Equal(["a.compose"], DesktopLook.BarOrder(["a.compose"]));
        Assert.Equal(SelectionAndBarsWalkProof.SessionsBar, DesktopLook.BarOrder(SelectionAndBarsWalkProof.SessionsBar));
        Assert.Equal(SelectionAndBarsWalkProof.TasksBar, DesktopLook.BarOrder(SelectionAndBarsWalkProof.TasksBar));
    }

    [Fact]
    public void TheWalkTellsTheMacsBarFromWindowsOldOne()
    {
        Assert.Null(SelectionAndBarsWalkProof.Bar("Sessions", 15, 600, SelectionAndBarsWalkProof.SessionsBar, SelectionAndBarsWalkProof.SessionsBar, true));
        // The old Sessions bar: SubtitleTextBlockStyle's 20 pt, the magnifier between Filter and New Chat.
        Assert.Contains("20 pt", SelectionAndBarsWalkProof.Bar("Sessions", 20, 600, SelectionAndBarsWalkProof.SessionsBar, SelectionAndBarsWalkProof.SessionsBar, true));
        Assert.Contains("reads", SelectionAndBarsWalkProof.Bar("Sessions", 15, 600,
            ["sessions.filter", "sessions.search", "sessions.compose"], SelectionAndBarsWalkProof.SessionsBar, true));
        Assert.Contains("weighs", SelectionAndBarsWalkProof.Bar("Tasks", 17, 400, SelectionAndBarsWalkProof.TasksBar, SelectionAndBarsWalkProof.TasksBar, false));
    }

    [Fact]
    public void TheWalkIsAskedForOnThePagesStandInWithItsThreePictures()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        var yml = File.ReadAllText(Path.Combine(dir, "ci", "windows.yml"));
        var line = yml.Split('\n').Single(l => l.Contains("\"selection-and-bars\"") && l.Contains("tag = "));
        Assert.Contains("windows/ci/fixtures/pages-fixture-gateway.py", line);
        Assert.Contains("\"selection-and-bars-sessions\"", line);
        Assert.Contains("\"selection-and-bars-tasks\"", line);
        var walk = File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Services", "ProofWalks.SelectionAndBars.cs"));
        Assert.Contains("Automation.NamedWalks[\"selection-and-bars\"]", walk);
        var registry = File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Services", "ProofWalks.cs"));
        Assert.Contains("RegisterSelectionAndBarsWalks();", registry);
    }

    // ------------------------------------------------------------------ [WIN-50] the remaining pages' bars

    static string WindowsDir()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return dir;
    }

    [Fact]
    public void JobsAndKanbanBarsReadAsTheMacs()
    {
        // Jobs: All Bots ⌄ · New Job · Search (JobRowView.swift: [search] + extra + [scope], trailing inward).
        Assert.Equal(["jobs.scope", "jobs.new", "jobs.search"], SelectionAndBarsWalkProof.JobsBar);
        // Kanban: How Kanban Works · New Task · Search (KanbanViewController.swift, then searchToEdge).
        Assert.Equal(["kanban.about", "kanban.new", "kanban.search"], SelectionAndBarsWalkProof.KanbanBar);
        Assert.Equal(SelectionAndBarsWalkProof.JobsBar, DesktopLook.BarOrder(SelectionAndBarsWalkProof.JobsBar));
        Assert.Equal(SelectionAndBarsWalkProof.KanbanBar, DesktopLook.BarOrder(SelectionAndBarsWalkProof.KanbanBar));
        // The magnifier at the edge whatever order a page gives: Kanban's own [About, Search, New] reads About · New · Search.
        Assert.Equal(SelectionAndBarsWalkProof.KanbanBar, DesktopLook.BarOrder(["kanban.about", "kanban.search", "kanban.new"]));
        Assert.Null(SelectionAndBarsWalkProof.Bar("Jobs", 15, 600, SelectionAndBarsWalkProof.JobsBar, SelectionAndBarsWalkProof.JobsBar, true));
        // The old Jobs and Kanban titles: 20 pt.
        Assert.Contains("20 pt", SelectionAndBarsWalkProof.Bar("Kanban", 20, 600, SelectionAndBarsWalkProof.KanbanBar, SelectionAndBarsWalkProof.KanbanBar, true));
    }

    [Fact]
    public void EveryPageButAChatTakesThePageBar()
    {
        Assert.False(DesktopLook.TakesPageBar("chat"));
        foreach (var place in DesktopLook.PageBarSources.Keys) Assert.True(DesktopLook.TakesPageBar(place), place);
        foreach (var place in new[] { "sessions", "tasks", "jobs", "artifacts", "files", "review", "terminal", "kanban", "tiles",
                     "command-center", "usage", "spawn-tree", "star-map", "marketplace", "capabilities", "profiles", "quick-actions" })
            Assert.True(DesktopLook.PageBarSources.ContainsKey(place), place);
    }

    [Fact]
    public void EveryConvertedPageDrawsItsTitleAndSideThroughPageBar()
    {
        var app = Path.Combine(WindowsDir(), "src", "HermesHQ.Windows");
        foreach (var (place, file) in DesktopLook.PageBarSources)
        {
            var source = File.ReadAllText(Path.Combine([app, .. file.Split('/')]));
            Assert.True(source.Contains("PageBar.Title(", StringComparison.Ordinal), $"{place}: {file} doesn't take the title token");
            // The Sessions page's side is in its XAML (WIN-49); every code-built bar takes the page's side from PageBar.
            if (place != "sessions")
                Assert.True(source.Contains("PageBar.Padding(", StringComparison.Ordinal), $"{place}: {file} doesn't take the page's side");
            // The old 20 pt semibold bar title is gone.
            Assert.DoesNotContain("FontSize = 20, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center", source);
        }
    }

    [Fact]
    public void TheWalkShootsJobsAndKanbanBarsToo()
    {
        var dir = WindowsDir();
        var yml = File.ReadAllText(Path.Combine(dir, "ci", "windows.yml"));
        var line = yml.Split('\n').Single(l => l.Contains("\"selection-and-bars\"") && l.Contains("tag = "));
        Assert.Contains("\"selection-and-bars-jobs\"", line);
        Assert.Contains("\"selection-and-bars-kanban\"", line);
        Assert.DoesNotContain("--no-kanban", line);   // the pages stand-in serves Kanban and Jobs unless told not to
        var walk = File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Services", "ProofWalks.SelectionAndBars.cs"));
        Assert.Contains("SelectionAndBarsWalkProof.JobsBar", walk);
        Assert.Contains("SelectionAndBarsWalkProof.KanbanBar", walk);
        Assert.Contains("shot(\"selection-and-bars-jobs\")", walk);
        Assert.Contains("shot(\"selection-and-bars-kanban\")", walk);
    }
}
