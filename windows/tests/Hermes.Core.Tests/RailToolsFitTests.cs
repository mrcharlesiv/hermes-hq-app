using System.Text.RegularExpressions;
using System.Xml.Linq;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-RAIL-TOOLS-FIT] The folded sidebar's top and the shell's Undo pill (CI run 44984518197, walk sidebar-search):
/// folded, Search and New Chat drew 8–10 px beside 15–16 px places, and "Archived “…”" stood in the 64-wide rail's
/// foot, cut to "Arc" over "Find". App/Mac/MacBotsRail.swift `MacSidebarTools` and App/Kit/UndoPill.swift at 93f984bb1.
public class RailToolsFitTests
{
    /// The glyphs are the Mac's at its chrome factor (`13 * MacSidebar.chrome`, `(folded ? 13 : 15) * MacSidebar.chrome`,
    /// drawn at a button's large scale). UI Scale — the Mac's `chrome`, `uiScalePercent / 100` — is applied on Windows
    /// once, to the whole window (ThemeService.ApplyScale scales the Frame the shell is in), so the FontSizes are the
    /// Mac's ink at 100 % and SidebarTools never multiplies them again. Folded they are the Mac's 13 pt symbols' ink
    /// (17 window points, 13 on the screen), not the 13 pt sizes read as ink (10 on the screen, the 8–10 px glyphs seen).
    [Fact]
    public void FoldedGlyphsAreTheMacsInkAtItsChrome()
    {
        Assert.Equal(SidebarSearch.OnScreen(17), SidebarSearch.RailGlassSize);
        Assert.Equal(SidebarSearch.OnScreen(17), SidebarSearch.ComposeGlyphSize(rail: true));
        Assert.True(SidebarSearch.RailGlassSize > SidebarSearch.OnScreen(13), $"glass {SidebarSearch.RailGlassSize}");
        Assert.True(SidebarSearch.ComposeGlyphSize(rail: true) > SidebarSearch.OnScreen(13));
        // Folded the pencil is the open one's 13/15 (the Mac's `folded ? 13 : 15`), within the rounding to half points.
        Assert.InRange(SidebarSearch.ComposeGlyphSize(rail: true) / SidebarSearch.ComposeGlyphSize(rail: false), 13.0 / 15 - 0.05, 13.0 / 15 + 0.05);
        // Each glyph fits its target with room round it.
        Assert.True(SidebarSearch.RailGlassSize <= SidebarSearch.RailSide - 8);

        var src = Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows");
        var tools = File.ReadAllText(Path.Combine(src, "Shell", "SidebarTools.cs"));
        Assert.Contains("FontSize = SidebarSearch.RailGlassSize", tools);
        Assert.Contains("FontSize = SidebarSearch.ComposeGlyphSize(rail: true)", tools);
        Assert.DoesNotMatch(new Regex(@"UiScale|State\.Scale|RasterizationScale"), tools);
        // The chrome factor reaches them: the shell is inside the Frame ThemeService scales.
        var theme = File.ReadAllText(Path.Combine(src, "Features", "Settings", "ThemeService.cs"));
        Assert.Contains("_content = (root as Panel)?.Children.OfType<Frame>().FirstOrDefault();", theme);
        Assert.Contains("_content.RenderTransform", theme);
    }

    /// The pill stands over the pane beside the sidebar (UndoPill.swift `shownPane`, Mac polish #32), never in the
    /// sidebar: no part of it is laid out within the rail's width.
    [Fact]
    public void ThePillStandsOverThePaneNotInTheRail()
    {
        var src = Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows");
        var xaml = XDocument.Parse(File.ReadAllText(Path.Combine(src, "Pages", "ShellPage.xaml")));
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        var host = xaml.Descendants().Single(e => (string?)e.Attribute(x + "Name") == "PillHost");
        var ancestors = host.Ancestors().ToList();
        Assert.DoesNotContain(ancestors, e => (string?)e.Attribute(x + "Name") == "SidebarPane");
        // In the pane's own grid, beside the frame, after it (drawn over it).
        var pane = host.Parent!;
        Assert.Contains(pane.Elements(), e => (string?)e.Attribute(x + "Name") == "ContentFrame");
        Assert.Equal("1", (string?)pane.Parent!.Attribute("Grid.Column"));
        Assert.True(host.ElementsBeforeSelf().Any(e => (string?)e.Attribute(x + "Name") == "ContentFrame"));
        Assert.Equal("Bottom", (string?)host.Attribute("VerticalAlignment"));

        // The pill's width: the pane's less 16 either side, the narrowest pane still a line's room; the rail's would not be.
        Assert.Equal(UndoPillPlacement.Inset, 16);
        Assert.True(UndoPillPlacement.WrapWidth(SidebarLayout.CompactRailWidth) < 50, "the rail can't hold a pill");
        Assert.True(UndoPillPlacement.WrapWidth(480) >= 400);

        // Above the foot, or above a chat's message box.
        Assert.Equal(8, UndoPillPlacement.Lift(600, null));
        Assert.Equal(8 + 120, UndoPillPlacement.Lift(600, 480));
        Assert.Equal(8, UndoPillPlacement.Lift(600, double.NaN));
        Assert.Equal(8, UndoPillPlacement.Lift(600, 700));

        var shell = File.ReadAllText(Path.Combine(src, "Pages", "ShellPage.xaml.cs"));
        Assert.Contains("UndoPillPlacement.Lift(", shell);
        Assert.Contains("FindName(\"ComposerBox\")", shell);
    }

    /// The walk's check of the real pill: in the rail (what run 44984518197 showed) it fails; over the pane it passes.
    [Fact]
    public void TheWalkFindsAPillInTheRail()
    {
        var rail = (0.0, 32.0, 64.0, 740.0);
        var pane = (64.0, 32.0, 960.0, 740.0);
        Assert.NotNull(UndoPillPlacement.Misplaced((4, 650, 56, 60), pane, rail, labelTrimmed: true));
        Assert.Contains("over the sidebar", UndoPillPlacement.Misplaced((4, 650, 56, 60), pane, rail, false));
        Assert.Null(UndoPillPlacement.Misplaced((400, 700, 300, 60), pane, rail, false));
        Assert.Contains("16 in", UndoPillPlacement.Misplaced((70, 700, 300, 60), pane, rail, false));
        Assert.Contains("foot", UndoPillPlacement.Misplaced((400, 710, 300, 60), pane, rail, false));
        Assert.Contains("cut short", UndoPillPlacement.Misplaced((400, 700, 300, 60), pane, rail, true));
        Assert.Equal("the pill has no size", UndoPillPlacement.Misplaced((400, 700, 0, 0), pane, rail, false));
        var walk = File.ReadAllText(Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows", "Services", "ProofWalks.ArchiveUndo.cs"));
        Assert.Contains("if (PillPlacement(shell) is { } misplaced) throw new InvalidOperationException(misplaced);", walk);
    }

    /// The Swift the placement is read from (full checkout only; the Windows CI mirror has no Swift).
    [Fact]
    public void PlacementIsTheSwifts()
    {
        var root = RepoRoot();
        if (!Directory.Exists(Path.Combine(root, "App"))) return;
        var pill = File.ReadAllText(Path.Combine(root, "App", "Kit", "UndoPill.swift"));
        foreach (var s in new[] { "let (host, view, paneBar) = shownPane(given, givenView)",
                     "pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)",
                     "pill.bottomAnchor.constraint(lessThanOrEqualTo: messageBar.topAnchor, constant: -8).isActive = true",
                     "pill.centerXAnchor.constraint(equalTo: view.centerXAnchor)",
                     "pill.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16)",
                     "pill.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16)",
                     "pill.wrapLines(within: view.bounds.width - 32)",
                     "return (split.detail, pane, (split.detail.topViewController as? ChatViewController)?.composer)" })
            Assert.Contains(s, pill);
        var header = File.ReadAllText(Path.Combine(root, "App", "Mac", "MacSidebarHeader.swift"));
        Assert.Contains("UIImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)", header);
        Assert.Contains("id: \"mac-sidebar.search\"", header);
        Assert.Contains("id: \"mac-sidebar.compose\"", header);
        var sidebar = File.ReadAllText(Path.Combine(root, "App", "Mac", "MacSidebar.swift"));
        Assert.Contains("static var chrome: CGFloat { CGFloat(ThemeTable.current.state.uiScalePercent) / 100 }", sidebar);
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "windows", "src"))) dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("repo root not found");
    }
}
