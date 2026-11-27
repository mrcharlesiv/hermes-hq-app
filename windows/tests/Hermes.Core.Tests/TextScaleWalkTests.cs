using System.Text.RegularExpressions;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-60] Larger text and high contrast on Windows: the text-scale walk's rules (Hermes.Core.Shell.TextScaleWalkProof),
/// the high-contrast walk's rules and palette (HighContrastWalkProof), and the source checks that keep Windows' text
/// scaling on and every one of the app's own theme brushes defined under the HighContrast dictionary.
public class TextScaleWalkTests
{
    private static string WindowsDir()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return dir;
    }

    private static string AppSource(string relative) => File.ReadAllText(Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", relative));

    // ------------------------------------------------------------------ text scale

    [Fact]
    public void TheScaleIsOneAndAHalf()
    {
        Assert.Equal(150, TextScaleWalkProof.RegistryPercent);
        Assert.Null(TextScaleWalkProof.Scale(1.5));
        Assert.Null(TextScaleWalkProof.Scale(1.5000001));
        Assert.Equal("UISettings.TextScaleFactor is 1, not 1.5: Windows didn't take TextScaleFactor=150", TextScaleWalkProof.Scale(1.0));
        Assert.Contains("is 2.25, not 1.5", TextScaleWalkProof.Scale(2.25));
        Assert.Equal(["text-scale-chat", "text-scale-tasks", "text-scale-settings"], TextScaleWalkProof.Shots);
    }

    [Fact]
    public void EveryAreaHasBothRulesAndEachCitesItsSwift()
    {
        foreach (var area in TextScaleWalkProof.Areas)
        {
            var wraps = TextScaleWalkProof.RuleFor(area, wraps: true);
            var oneLine = TextScaleWalkProof.RuleFor(area, wraps: false);
            Assert.NotNull(oneLine);
            Assert.True(oneLine!.MacTruncates, $"{area}: its one-line words are cut short on the Mac");
            if (area != TextScaleWalkProof.Sidebar)
            {
                Assert.NotNull(wraps);
                Assert.False(wraps!.MacTruncates, $"{area}: the Mac wraps its running words");
            }
        }
        foreach (var rule in TextScaleWalkProof.Rules)
        {
            Assert.StartsWith("App/", rule.Swift);
            Assert.Contains(".swift `", rule.Swift);
            Assert.False(string.IsNullOrWhiteSpace(rule.What));
        }
        // The Mac's sidebar rows truncate (names, statuses, a chat's line), so the sidebar has no wrapping rule.
        Assert.Null(TextScaleWalkProof.RuleFor(TextScaleWalkProof.Sidebar, wraps: true));
        Assert.Contains("byTruncatingTail", TextScaleWalkProof.RuleFor(TextScaleWalkProof.Sidebar, false)!.Swift);
        Assert.Contains(".lineLimit(large ? 4 : 2)", TextScaleWalkProof.RuleFor(TextScaleWalkProof.Tasks, true)!.Swift);
        Assert.Contains(".lineLimit(large ? nil : 1)", TextScaleWalkProof.RuleFor(TextScaleWalkProof.Tasks, false)!.Swift);
        Assert.Contains(".fixedSize(horizontal: false, vertical: true)", TextScaleWalkProof.RuleFor(TextScaleWalkProof.Settings, true)!.Swift);
        Assert.Contains(".truncationMode(.middle)", TextScaleWalkProof.RuleFor(TextScaleWalkProof.Settings, false)!.Swift);
    }

    [Fact]
    public void OneLineWordsCutShortPassWhereTheMacTruncates()
    {
        Assert.Null(TextScaleWalkProof.Judge(new CutText(TextScaleWalkProof.Sidebar, "sidebar.chat", Wraps: false, MaxLines: 0, Length: 40)));
        Assert.Null(TextScaleWalkProof.Judge(new CutText(TextScaleWalkProof.Chat, "Title", Wraps: false, MaxLines: 0, Length: 30)));
        Assert.Null(TextScaleWalkProof.Judge(new CutText(TextScaleWalkProof.Tasks, "tasks.row.t1", Wraps: false, MaxLines: 0, Length: 60)));
        Assert.Null(TextScaleWalkProof.Judge(new CutText(TextScaleWalkProof.Settings, "settings.gateway-card", Wraps: false, MaxLines: 0, Length: 25)));
        // A line limit (a step's title, two lines) is a cut the Mac makes too.
        Assert.Null(TextScaleWalkProof.Judge(new CutText(TextScaleWalkProof.Transcript, "chat.transcript", Wraps: true, MaxLines: 2, Length: 90)));
    }

    [Fact]
    public void RunningWordsCutShortFail()
    {
        // A bubble's words, a task's name, a setting's title: wrapping text that a fixed size clips.
        var bubble = TextScaleWalkProof.Judge(new CutText(TextScaleWalkProof.Transcript, "chat.transcript", Wraps: true, MaxLines: 0, Length: 300));
        Assert.NotNull(bubble);
        Assert.Contains("a message's words", bubble);
        Assert.Contains("App/Chat/Cells/ChatTextViews.swift", bubble);
        var task = TextScaleWalkProof.Judge(new CutText(TextScaleWalkProof.Tasks, "tasks.row.t2", Wraps: true, MaxLines: 0, Length: 80));
        Assert.Contains("the Mac wraps", task);
        Assert.Contains("tasks.row.t2", task);
        Assert.NotNull(TextScaleWalkProof.Judge(new CutText(TextScaleWalkProof.Settings, "", Wraps: true, MaxLines: 0, Length: 20)));
        // Wrapping text in the sidebar: no Mac rule (its rows truncate), so it can't pass unnoticed.
        Assert.Contains("no Mac rule", TextScaleWalkProof.Judge(new CutText(TextScaleWalkProof.Sidebar, "x", Wraps: true, MaxLines: 0, Length: 5)));
        Assert.Contains("no Mac rule", TextScaleWalkProof.Judge(new CutText("elsewhere", "x", Wraps: false, MaxLines: 0, Length: 5)));
    }

    [Fact]
    public void TheReportNamesEveryFindingAndEveryVisitedPage()
    {
        Assert.Null(TextScaleWalkProof.Report([], ["Chats", "Tasks", "Settings"]));
        Assert.Null(TextScaleWalkProof.Report([new CutText(TextScaleWalkProof.Sidebar, "sidebar.chat", false, 0, 12)], ["Chats", "Tasks", "Settings"]));
        var wrong = TextScaleWalkProof.Report(
            [new CutText(TextScaleWalkProof.Sidebar, "sidebar.chat", false, 0, 12), new CutText(TextScaleWalkProof.Tasks, "tasks.row.t9", true, 0, 70)],
            ["Chats", "Tasks", "Settings"]);
        Assert.NotNull(wrong);
        Assert.StartsWith("1 text cut short at 150 % where the Mac wraps it:", wrong);
        Assert.Contains("tasks.row.t9", wrong);
        Assert.DoesNotContain("sidebar.chat", wrong);
        // A page never visited is a failure of its own.
        Assert.Contains("Settings was never visited", TextScaleWalkProof.Report([], ["Chats", "Tasks"]));
    }

    /// "file:line" for each place that turns Windows' text scaling off for a text.
    internal static List<string> ScalingTurnedOff(string file, string source)
    {
        var found = new List<string>();
        foreach (Match m in Regex.Matches(source, @"IsTextScaleFactorEnabled\s*(?:=\s*""\s*False\s*""|=\s*false\b|,\s*false\s*\))", RegexOptions.IgnoreCase))
            found.Add($"{file}:{source[..m.Index].Count(c => c == '\n') + 1}");
        return found;
    }

    [Fact]
    public void TheRuleCatchesScalingTurnedOff()
    {
        Assert.Single(ScalingTurnedOff("a.xaml", "<TextBlock IsTextScaleFactorEnabled=\"False\" />"));
        Assert.Single(ScalingTurnedOff("a.xaml", "<TextBlock IsTextScaleFactorEnabled = \"false\" />"));
        Assert.Single(ScalingTurnedOff("a.cs", "var t = new TextBlock { IsTextScaleFactorEnabled = false };"));
        Assert.Single(ScalingTurnedOff("a.cs", "t.SetValue(TextBlock.IsTextScaleFactorEnabledProperty, false);".Replace("Property", "")));
        Assert.Empty(ScalingTurnedOff("a.cs", "var t = new TextBlock { IsTextScaleFactorEnabled = true };"));
        Assert.Empty(ScalingTurnedOff("a.xaml", "<TextBlock IsTextScaleFactorEnabled=\"True\" />"));
    }

    [Fact]
    public void NoTextTurnsWindowsTextScalingOff()
    {
        var src = Path.Combine(WindowsDir(), "src");
        var found = Directory.EnumerateFiles(src, "*.*", SearchOption.AllDirectories)
            .Where(p => p.EndsWith(".cs", StringComparison.Ordinal) || p.EndsWith(".xaml", StringComparison.Ordinal))
            .Where(p => !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}") && !p.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}"))
            .SelectMany(p => ScalingTurnedOff(Path.GetRelativePath(src, p), File.ReadAllText(p)))
            .ToList();
        Assert.True(found.Count == 0, "IsTextScaleFactorEnabled turned off (the text ignores Windows' Text size):\n" + string.Join("\n", found));
    }

    // ------------------------------------------------------------------ high contrast

    [Fact]
    public void EveryOwnThemeBrushHasAHighContrastColour()
    {
        // ThemeService paints the app's own brushes ("HQ…Brush") in its Light and Dark dictionaries; under a Windows
        // contrast theme WinUI looks them up in "HighContrast", which must hold every one of them.
        var source = AppSource(Path.Combine("Features", "Settings", "ThemeService.cs"));
        var keys = Regex.Matches(source, @"\(""(HQ[A-Za-z0-9]+Brush)"",").Select(m => m.Groups[1].Value).ToList();
        Assert.True(keys.Count >= 20, $"found only {keys.Count} HQ brushes in ThemeService.cs");
        var missing = keys.Where(k => HighContrastWalkProof.SystemColourFor(k) == null).ToList();
        Assert.True(missing.Count == 0, "no High Contrast colour for: " + string.Join(", ", missing));
        Assert.Contains("ThemeDictionary(resources, \"HighContrast\")", source);
    }

    [Fact]
    public void ThePaletteUsesWindowsContrastColoursOnly()
    {
        Assert.Equal("WindowText", HighContrastWalkProof.SystemColourFor("HQLabelBrush"));
        Assert.Equal("Window", HighContrastWalkProof.SystemColourFor("HQPageBrush"));
        Assert.Equal("Highlight", HighContrastWalkProof.SystemColourFor("HQTintBrush"));
        Assert.Equal("HighlightText", HighContrastWalkProof.SystemColourFor("HQOnTintBrush"));
        // [WIN-CONTRAST-BUBBLE] Your bubble is the theme's Highlight pair (the Mac's tint under white words).
        Assert.Equal("Highlight", HighContrastWalkProof.SystemColourFor("HQMeBubbleBrush"));
        Assert.Equal("HighlightText", HighContrastWalkProof.SystemColourFor("HQMeTextBrush"));
        Assert.Equal("Highlight", HighContrastWalkProof.SystemColourFor("HQMeBorderBrush"));
        Assert.Null(HighContrastWalkProof.SystemColourFor("HQNoSuchBrush"));
        foreach (var (_, element) in HighContrastWalkProof.Palette)
            Assert.Contains(element, HighContrastWalkProof.SystemColours);
        Assert.Equal(["high-contrast-chat", "high-contrast-tasks", "high-contrast-settings"], HighContrastWalkProof.Shots);
    }

    [Fact]
    public void InkIsOneOfTheContrastColours()
    {
        uint[] system = [0xFFFFFF, 0x000000, 0x1AEBFF, 0x3FF23F];
        Assert.Null(HighContrastWalkProof.Ink("Chats", "Title", 0xFFFFFF, system));
        Assert.Null(HighContrastWalkProof.Ink("Chats", "Title", 0xFF1AEBFF, system));   // alpha ignored
        var wrong = HighContrastWalkProof.Ink("Tasks", "tasks.row.t1", 0xFF3B30, system);
        Assert.Equal("Tasks · tasks.row.t1 · ink #FF3B30 isn't a contrast theme colour", wrong);
        Assert.Null(HighContrastWalkProof.Report([], ["Chats", "Tasks", "Settings"]));
        Assert.StartsWith("1 text drawn in its own colour under a contrast theme:", HighContrastWalkProof.Report([wrong!], ["Chats", "Tasks", "Settings"]));
        Assert.Contains("Tasks was never visited", HighContrastWalkProof.Report([], ["Chats", "Settings"]));
        Assert.Null(HighContrastWalkProof.On(true));
        Assert.Equal("SPI_GETHIGHCONTRAST is off: Windows didn't switch to a contrast theme", HighContrastWalkProof.On(false));
    }

    [Fact]
    public void TasksToneWordsFollowTheContrastTheme()
    {
        // A task's bot line and a priority's colour were literal brushes, kept under a contrast theme (SystemParametersInfo
        // SPI_SETHIGHCONTRAST): they go through ThemeService.Ink, which hands back the theme's text brush there.
        var tasks = AppSource(Path.Combine("Features", "Tasks", "TasksPage.cs"));
        Assert.DoesNotContain("color: Solid(ToneColor(words.Tone))", tasks);
        Assert.Contains("ThemeService.Ink(ToneColor(words.Tone))", tasks);
        var pane = AppSource(Path.Combine("Features", "Tasks", "TaskPane.cs"));
        Assert.DoesNotContain("button.Foreground = Solid(c)", pane);
        Assert.Contains("ThemeService.Ink(c)", pane);
    }
}
