using System.Text.RegularExpressions;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// The sidebar's Search (App/Mac/MacBotsRail.swift `MacSidebarTools`, SidebarType.swift at 93f984bb1): a button that
/// opens Open Quickly exactly as Ctrl+K does, "Search" with a quiet "Ctrl+K" in a well beside New Chat; folded, the two
/// side by side over a hairline. The old field ("Search   Ctrl+K") filtered on its own while Ctrl+K opened the panel.
public class SidebarSearchTests
{
    [Fact]
    public void WordsAreTheMacsWithWindowsKeys()
    {
        Assert.Equal("shell.search", SidebarSearch.SearchAutomationId);
        Assert.Equal("Search", SidebarSearch.SearchName);
        Assert.Equal("Ctrl+K", SidebarSearch.SearchHint);
        Assert.Equal("Search or jump to\u2026 (Ctrl+K)", SidebarSearch.SearchToolTip);
        Assert.Equal("New Chat (Ctrl+N)", SidebarSearch.ComposeToolTip);
        Assert.Equal("shell.compose", SidebarSearch.ComposeAutomationId);
        Assert.Equal("shell.tools", SidebarSearch.ToolsAutomationId);
    }

    /// SidebarType.current (search 17, shortcut 14.5) and the tools' 34 / 24 squares, at the Mac's 77 %.
    [Fact]
    public void SizesAreTheMacSidebarsOnTheScreen()
    {
        Assert.Equal(17 * 0.77, SidebarSearch.WordSize);
        Assert.Equal(15 * 0.77, SidebarSearch.HintSize); // 14.5 pt, raised to MacSidebar.font’s 15 pt legibility floor
        Assert.Equal(26, SidebarSearch.OpenSide);
        Assert.Equal(7, SidebarSearch.WellCorner);
        // A Segoe Fluent glyph's ink is about its FontSize, but an SF Symbol's drawn image is about 1.2x its point size,
        // so the glyphs follow the Mac's drawn ink (93f984bb1, measured in window points): glass 16x17 open and
        // folded, the pencil 19 open and 17 folded. The symbols' 13/15 pt sizes drew 10 and 11.5 px, 20 % small.
        Assert.Equal(13, SidebarSearch.GlassSize);
        Assert.Equal(13, SidebarSearch.RailGlassSize);
        Assert.Equal(14.5, SidebarSearch.ComposeGlyphSize(rail: false));
        Assert.Equal(13, SidebarSearch.ComposeGlyphSize(rail: true));
        Assert.Equal(18.5, SidebarSearch.OnScreen(24));
        Assert.Equal((0.06, 0.08), (SidebarSearch.WellAlpha(false), SidebarSearch.WellAlpha(true)));
        Assert.Equal((0.10, 0.13), (SidebarSearch.WellHoverAlpha(false), SidebarSearch.WellHoverAlpha(true)));
        Assert.Equal((0.12, 0.14), (SidebarSearch.RuleAlpha(false), SidebarSearch.RuleAlpha(true)));
    }

    /// Open: Search then New Chat; folded (compact or named rail): side by side over the hairline, and the pair fits the
    /// compact rail inside its padding.
    [Fact]
    public void RailPutsTheTwoSideBySide()
    {
        Assert.Equal(SidebarSearch.Arrangement.SearchThenCompose, SidebarSearch.Layout(rail: false));
        Assert.Equal(SidebarSearch.Arrangement.SideBySideWithRule, SidebarSearch.Layout(rail: true));
        Assert.True(SidebarSearch.RailRowWidth <= SidebarLayout.CompactRailWidth - 8, $"{SidebarSearch.RailRowWidth} wide");
    }

    /// The shell has no search field of its own any more: the open well and the rail's Search both run the method Ctrl+K
    /// runs, and nothing still says "Search   Ctrl+K" over a field that no longer opens what Ctrl+K opens.
    [Fact]
    public void TheShellsSearchOpensOpenQuickly()
    {
        var src = Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows");
        var xaml = File.ReadAllText(Path.Combine(src, "Pages", "ShellPage.xaml"));
        var shell = File.ReadAllText(Path.Combine(src, "Pages", "ShellPage.xaml.cs"));
        Assert.DoesNotContain("AutoSuggestBox", xaml);
        Assert.DoesNotContain("Search   Ctrl+K", xaml);
        Assert.DoesNotContain("RailSearch_Click", xaml);
        Assert.DoesNotContain("AutoSuggestBox", shell);
        Assert.DoesNotContain("Search.Focus(", shell);
        Assert.Contains("AddShortcut(ShellKeys.OpenQuickly, ShowOpenQuickly);", shell);
        Assert.Matches(new Regex(@"SidebarTools\.Build\(rail, ShowOpenQuickly,"), shell);
        Assert.Contains("x:Name=\"ToolsHost\"", xaml);

        var tools = File.ReadAllText(Path.Combine(src, "Shell", "SidebarTools.cs"));
        foreach (var s in new[] { "SidebarSearch.SearchAutomationId", "SidebarSearch.SearchName", "SidebarSearch.SearchToolTip",
                     "SidebarSearch.SearchHint", "SidebarSearch.ComposeAutomationId", "SidebarSearch.ComposeToolTip",
                     "SidebarSearch.Layout(rail)", "SidebarSearch.RuleGap", "ButtonBackgroundPointerOver" })
            Assert.Contains(s, tools);
        // A click runs the action it was given (Open Quickly's Show, through the shell), nothing of its own.
        Assert.Matches(new Regex(@"search\.Click \+= \(_, _\) => openQuickly\(\);"), tools);
        Assert.Matches(new Regex(@"compose\.Click \+= \(_, _\) => newChat\(\);"), tools);
    }

    /// The words and sizes above are the Swift source's (full checkout only; the Windows CI mirror has no Swift).
    [Fact]
    public void WordsAreTheSwiftStrings()
    {
        var root = RepoRoot();
        if (!Directory.Exists(Path.Combine(root, "App"))) return;
        var header = File.ReadAllText(Path.Combine(root, "App", "Mac", "MacSidebarHeader.swift"));
        foreach (var s in new[] { "accessibilityIdentifier = \"mac-sidebar.tools\"",
                     "label: \"Search\", tip: \"Search or jump to\u2026 (\u2318K)\", id: \"mac-sidebar.search\"",
                     "label: \"New Chat\", tip: \"New Chat (\u2318N)\", id: \"mac-sidebar.compose\"",
                     "KeyCommands.openQuickly", "KeyCommands.newChat",
                     "UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.09)",
                     "UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.055)" })
            Assert.Contains(s, header);
        var workspaceBar = File.ReadAllText(Path.Combine(root, "App", "Mac", "MacWorkspaceBar.swift"));
        Assert.Contains("searchButton.accessibilityIdentifier = \"mac-sidebar.search\"", workspaceBar);
        var type = File.ReadAllText(Path.Combine(root, "App", "Mac", "SidebarType.swift"));
        Assert.Contains("search: 17, shortcut: 14.5,", type);
        Assert.Contains("static let shipping = current", type);
        var sidebar = File.ReadAllText(Path.Combine(root, "App", "Mac", "MacSidebar.swift"));
        Assert.Contains("withAlphaComponent(0.5)", sidebar);
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "windows", "src"))) dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("repo root not found");
    }
}
