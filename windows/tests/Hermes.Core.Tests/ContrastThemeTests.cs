using Hermes.Core.Settings;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-CONTRAST-BUBBLE] Under a Windows contrast theme every fill that carries words is a pair of the theme's own
/// colours (Hermes.Core.Settings.ContrastTheme): your bubble and the picked pill Highlight under HighlightText, a pill not
/// picked ButtonFace under ButtonText, the rest Window under WindowText; the high-contrast walk's judge; and the source
/// checks that the bubble, the pills and code lookups of the app's brushes follow it.
public class ContrastThemeTests
{
    private static string WindowsDir()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return dir;
    }

    private static string Source(string relative) => File.ReadAllText(Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", relative));

    // The runner's Aquatic-like theme from CI run 45171524778's log (synthetic names, its six colours).
    private static readonly Dictionary<string, uint> Aquatic = new()
    {
        ["Window"] = 0x202020, ["WindowText"] = 0xFFFFFF, ["GrayText"] = 0xA6A6A6, ["Highlight"] = 0x8EE3F0,
        ["HighlightText"] = 0x263B50, ["Hotlight"] = 0x75E9FC, ["ButtonFace"] = 0x202020, ["ButtonText"] = 0xFFFFFF,
    };

    [Theory]
    [InlineData(ContrastTheme.Surface.UserBubble, "Highlight", "HighlightText", "Highlight")]
    [InlineData(ContrastTheme.Surface.PickedPill, "Highlight", "HighlightText", "Highlight")]
    [InlineData(ContrastTheme.Surface.Pill, "ButtonFace", "ButtonText", "ButtonText")]
    [InlineData(ContrastTheme.Surface.Window, "Window", "WindowText", "WindowText")]
    public void EachSurfaceIsAPairOfTheThemesColours(ContrastTheme.Surface surface, string fill, string ink, string edge)
    {
        var c = ContrastTheme.For(surface);
        Assert.Equal((fill, ink, edge), (c.Fill, c.Ink, c.Edge));
        foreach (var element in new[] { c.Fill, c.Ink, c.Edge }) Assert.Contains(element, HighContrastWalkProof.SystemColours);
        Assert.NotEqual(c.Fill, c.Ink);
    }

    [Fact]
    public void APillIsPickedOrAButton()
    {
        Assert.Equal(ContrastTheme.Surface.PickedPill, ContrastTheme.PillSurface(true));
        Assert.Equal(ContrastTheme.Surface.Pill, ContrastTheme.PillSurface(false));
    }

    [Fact]
    public void TheAppsBubbleBrushesFollowTheUserBubblePair()
    {
        var pair = ContrastTheme.For(ContrastTheme.Surface.UserBubble);
        Assert.Equal(pair.Fill, HighContrastWalkProof.SystemColourFor("HQMeBubbleBrush"));
        Assert.Equal(pair.Ink, HighContrastWalkProof.SystemColourFor("HQMeTextBrush"));
        Assert.Equal(pair.Edge, HighContrastWalkProof.SystemColourFor("HQMeBorderBrush"));
        // The tint and the words on it are the same pair (your bubble is the Mac's tint).
        Assert.Equal(HighContrastWalkProof.SystemColourFor("HQTintBrush"), HighContrastWalkProof.SystemColourFor("HQMeBubbleBrush"));
        Assert.Equal(HighContrastWalkProof.SystemColourFor("HQOnTintBrush"), HighContrastWalkProof.SystemColourFor("HQMeTextBrush"));
    }

    [Fact]
    public void TheJudgePassesThePairWithoutABackplate()
    {
        Assert.Null(ContrastTheme.Judge("bubble", ContrastTheme.Surface.UserBubble, 0x8EE3F0, 0x263B50, false, Aquatic));
        Assert.Null(ContrastTheme.Judge("pill", ContrastTheme.Surface.Pill, 0xFF202020, 0xFFFFFFFF, false, Aquatic));   // alpha ignored
    }

    [Fact]
    public void TheJudgeNamesTheShotsAccentBubble()
    {
        // 02-high-contrast-chat.png: the accent blue under white words on the system's backplate.
        var wrong = ContrastTheme.Judge("Chats · your bubble", ContrastTheme.Surface.UserBubble, 0x0A5CFF, 0xFFFFFF, true, Aquatic);
        Assert.NotNull(wrong);
        Assert.Contains("fill #0A5CFF isn't Highlight (#8EE3F0)", wrong);
        Assert.Contains("words #FFFFFF aren't HighlightText (#263B50)", wrong);
        Assert.Contains("backplate", wrong);
    }

    [Theory]
    [InlineData(true, "Highlight", "HighlightText", "ButtonFace")]
    [InlineData(false, "ButtonFace", "ButtonText", "Highlight")]
    public void PaintingTheOtherPillsFillFailsEvenWithTheRightInk(bool picked, string fill, string ink, string painted)
    {
        var surface = ContrastTheme.PillSurface(picked);
        Assert.Null(ContrastTheme.Judge("pill", surface, Aquatic[fill], Aquatic[ink], false, Aquatic));
        Assert.Equal($"pill ({surface}): fill #{Aquatic[painted]:X6} isn't {fill} (#{Aquatic[fill]:X6})",
            ContrastTheme.Judge("pill", surface, Aquatic[painted], Aquatic[ink], false, Aquatic));
    }

    [Fact]
    public void ThePillWalkDoesNotReadTheControlsConfiguredBrushes()
    {
        var walk = Source("Services/ProofWalks.TextScale.cs") + Source("Services/ProofWalks.TaskPills.cs");
        Assert.DoesNotContain("pill.Resources", walk);
        Assert.DoesNotContain("pill.Background", walk);
        Assert.Contains("presenter.Background", walk);
        Assert.Contains("PillMismatchControl(host, named)", walk);
        Assert.Contains("var measured = PillPaint(probe, named, out _)", walk);
    }

    [Fact]
    public void TheViewportProofReceivesTheMeasuredFillAndTheScrollTemplatePart()
    {
        var walk = Source("Services/ProofWalks.TaskPills.cs");
        Assert.Contains("InPillViewport(ContentPresenter presenter)", walk);
        Assert.Contains("PillViewport.InView(Bounds(presenter), Boundaries())", walk);
        Assert.Contains("PillViewport.Boundary.ContentViewport, Bounds(viewport)", walk);
    }

    [Fact]
    public void TheJudgeNamesTheBackplateAloneAndAMissingColour()
    {
        Assert.Equal("pill (PickedPill): words drawn on the system's backplate",
            ContrastTheme.Judge("pill", ContrastTheme.Surface.PickedPill, 0x8EE3F0, 0x263B50, true, Aquatic));
        var none = ContrastTheme.Judge("pill", ContrastTheme.Surface.Pill, 0x202020, 0xFFFFFF, false, new Dictionary<string, uint>());
        Assert.Contains("isn't ButtonFace", none);
    }

    [Fact]
    public void CodeLookupsTakeTheContrastBrush()
    {
        var theme = Source("Features/Settings/ThemeService.cs");
        Assert.Contains("if (!SystemHighContrast) return b;", theme);
        Assert.Contains("ContrastBrushes.TryGetValue(key, out var inContrast) ? inContrast.Brush : null", theme);
        Assert.Contains("words.HighContrastAdjustment = ElementHighContrastAdjustment.None", theme);
    }

    [Fact]
    public void TheBubbleAndThePillsDrawTheirWordsInThePair()
    {
        var message = Source("Controls/MessageView.cs");
        Assert.Contains("ThemeService.ContrastWords(words)", message);
        Assert.Contains("Name = UserBubbleName", message);
        var tasks = Source("Features/Tasks/TasksPage.cs");
        Assert.Contains("ContrastTheme.PillSurface(picked)", tasks);
        Assert.Contains("ContrastPill(pill, \"ToggleButton\"", tasks);
        Assert.Contains("ContrastPill(add, \"Button\"", tasks);
        var walk = Source("Services/ProofWalks.TextScale.cs");
        Assert.Contains("UserBubbleFills(roots, named)", walk);
        Assert.Contains("PillFills(roots, named)", walk);
        Assert.Contains("throw new InvalidOperationException($\"{fills.Count} fill", walk);
    }
}
