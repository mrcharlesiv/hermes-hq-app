using Hermes.Core.Gateways;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-FOOTER-GATEWAY-CLIP] The sidebar foot's gateway name as the Mac fits it (App/Mac/MacSidebar.swift `showGateway`):
/// one line cut in the middle (`.byTruncatingMiddle`) to the room the gear leaves (`settingsButton.leadingAnchor - 6`),
/// the chevrons and news dot whole (`.required` hugging and compression resistance). Seen hard-clipped on Windows at
/// 150 % text as "127.0.0.1:98" at the gear, no ellipsis.
public class GatewayFootTests
{
    private const string Host = "127.0.0.1:9863";

    /// 7 per character, as a fixed-width face at a larger text size.
    private static double Mono(string s) => s.Length * 7.0;

    private static string WindowsDir()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return dir;
    }

    private static string AppSource(string relative) => File.ReadAllText(Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", relative));

    [Fact]
    public void TheMacsGaps()
    {
        Assert.Equal(6, GatewayFootFit.DotGap);    // gatewayDot.trailingAnchor … gatewayLine.leadingAnchor, constant: -6
        Assert.Equal(4, GatewayFootFit.LineGap);   // gatewayLine.spacing = 4
        Assert.Equal(6, GatewayFootFit.GearGap);   // gatewayLine.trailingAnchor ≤ settingsButton.leadingAnchor - 6
    }

    [Fact]
    public void TheNameGivesWayNotTheChevronsOrTheNewsDot()
    {
        Assert.Equal(100, GatewayFootFit.NameRoom(100));
        Assert.Equal(100 - 4 - 9, GatewayFootFit.NameRoom(100, arrows: 9));
        Assert.Equal(100 - 4 - 9 - 4 - 6, GatewayFootFit.NameRoom(100, arrows: 9, news: 6));
        Assert.Equal(0, GatewayFootFit.NameRoom(10, arrows: 9, news: 6));
        Assert.True(double.IsPositiveInfinity(GatewayFootFit.NameRoom(double.PositiveInfinity, 9, 6)));
    }

    [Fact]
    public void AFittingNameIsWholeAndALongOneIsCutInTheMiddle()
    {
        Assert.Equal(Host, GatewayFootFit.Name(Host, Mono(Host) + 1, Mono));
        Assert.Equal(Host, GatewayFootFit.Name(Host, double.PositiveInfinity, Mono));
        Assert.Equal("", GatewayFootFit.Name("", 50, Mono));

        // The clipped case: room for 12 characters at most (a unit short of the room), never the tail cut "127.0.0.1:98".
        var cut = GatewayFootFit.Name(Host, 12 * 7 + 1, Mono);
        Assert.Equal("127.0.…:9863", cut);
        Assert.True(Mono(cut) <= 12 * 7);
        Assert.True(GatewayFootFit.IsMiddleCut(Host, cut));
        Assert.StartsWith("127.0", cut);
        Assert.EndsWith(":9863", cut);

        // Narrower still: fewer characters either side, the port's end kept; nothing at all when not even "…" fits.
        var narrow = GatewayFootFit.Name(Host, 6 * 7 + 1, Mono);
        Assert.Equal("127…63", narrow);
        Assert.Equal("", GatewayFootFit.Name(Host, 5, Mono));
    }

    [Fact]
    public void TheWalkJudgesTheDrawnFoot()
    {
        // Whole, inside its room, 10 before the gear: passes. Cut in the middle there: passes.
        Assert.Null(GatewayFootFit.Judge(Host, Host, nameRight: 150, roomRight: 160, gearLeft: 160, tailCut: false));
        Assert.Null(GatewayFootFit.Judge(Host, "127.0…:9863", 150, 160, 160, false));

        // The CI shot: the name runs past its column into the gear, words clipped with no ellipsis.
        var clip = GatewayFootFit.Judge(Host, Host, nameRight: 175, roomRight: 160, gearLeft: 162, tailCut: false);
        Assert.NotNull(clip);
        Assert.Contains("hard-clipped", clip);
        Assert.Contains("before the gear, not at least 6", clip);

        // Cut at its end by the TextBlock's own ellipsis, or a shown name that isn't the whole one cut in the middle.
        Assert.Contains("cut at its end", GatewayFootFit.Judge(Host, Host, 150, 160, 160, tailCut: true));
        Assert.Contains("not cut in the middle", GatewayFootFit.Judge(Host, "127.0.0.1:98", 150, 160, 160, false));
        Assert.False(GatewayFootFit.IsMiddleCut(Host, "127.0.0.1:98"));
        Assert.False(GatewayFootFit.IsMiddleCut(Host, "127…0…9863"));
        Assert.False(GatewayFootFit.IsMiddleCut(Host, "128.0…9863"));
        Assert.True(GatewayFootFit.IsMiddleCut(Host, "…"));
    }

    [Fact]
    public void TheFootCutsTheNameToItsRoomWithNoFixedCap()
    {
        var foot = AppSource(Path.Combine("Features", "Gateways", "GatewayFoot.cs"));
        Assert.DoesNotContain("MaxWidth = 170", foot);
        Assert.Contains("protected override Windows.Foundation.Size MeasureOverride", foot);
        Assert.Contains("GatewayFootFit.NameRoom(", foot);
        Assert.Contains("GatewayFootFit.Name(_whole, room, MeasureName)", foot);
        Assert.Contains("TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, MaxLines = 1", foot);
        Assert.Contains("public const string NameId = \"shell.gateway\"", foot);
        // The line's gaps are the Mac's, not a StackPanel's single spacing.
        Assert.DoesNotContain("Spacing = 6", foot);

        // The rail hides the gateway line, the feature's as well as the default's (`shown = tidy && !isCollapsed`).
        var shell = AppSource(Path.Combine("Pages", "ShellPage.xaml.cs"));
        Assert.Contains("GatewayFootHost.Visibility = rail ? Visibility.Collapsed : Visibility.Visible;", shell);
        Assert.Contains("x:Name=\"SettingsButton\"", AppSource(Path.Combine("Pages", "ShellPage.xaml")));
    }

    [Fact]
    public void TheTextScaleWalkShootsTheFootAtItsNarrowest()
    {
        Assert.Equal("text-scale-foot", TextScaleWalkProof.FootShot);
        var walk = AppSource(Path.Combine("Services", "ProofWalks.TextScale.cs"));
        Assert.Contains("FootAtTextScaleAsync(shot)", walk);
        Assert.Contains("shell.ShowOpenWidthForWalk(SidebarLayout.NarrowestOpen)", walk);
        Assert.Contains("await shot(TextScaleWalkProof.FootShot)", walk);
        Assert.Contains("GatewayFootFit.Judge(", walk);
        var ci = File.ReadAllText(Path.Combine(WindowsDir(), "ci", "windows.yml"));
        Assert.Contains("\"text-scale-settings\",\"text-scale-foot\")", ci);
    }
}
