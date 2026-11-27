using System.Text.RegularExpressions;
using Hermes.Core.Transcripts;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-LINK-CHIP-FIT] A link chip stays inside a narrow reply (App/Chat/Cells/LinkChipView.swift `width(maxText:)` at
/// 93f984bb1). Synthetic widths only, in the transcript's layout units; no page is read. This is headless arithmetic and
/// source coverage: how the card actually looks at a real Windows DPI and UI Scale still needs a Windows run.
public class LinkChipFitTests
{
    private const string View = "HermesHQ.Windows/Features/Transcript/LinkChipView.cs";

    [Theory]
    [InlineData(760, 300)]     // the full reply column: the cap
    [InlineData(300, 300)]
    [InlineData(301, 300)]
    [InlineData(299, 299)]
    [InlineData(220, 220)]     // a narrow window: the whole column, never past it
    [InlineData(48, 48)]
    [InlineData(0, 0)]
    [InlineData(-5, 0)]
    public void ItTakesTheColumnUpToTheCap(double available, double width) =>
        Assert.Equal(width, LinkChipFit.Width(available));

    [Fact]
    public void AnUnboundedOrUnknownColumn()
    {
        Assert.Equal(LinkChipFit.MaxWidth, LinkChipFit.Width(double.PositiveInfinity));
        Assert.Equal(0, LinkChipFit.Width(double.NaN));
    }

    [Fact]
    public void AColumnResizingFromWideToNarrowAndBackFollowsIt()
    {
        double[] column = [760, 520, 300, 260, 180, 120, 180, 400, 760];
        Assert.Equal([300, 300, 300, 260, 180, 120, 180, 300, 300], column.Select(LinkChipFit.Width).ToArray());
        // Never wider than the column it is in.
        foreach (var w in Enumerable.Range(0, 900)) Assert.True(LinkChipFit.Width(w) <= w);
    }

    [Theory]
    [InlineData(1.0)]
    [InlineData(1.25)]
    [InlineData(1.5)]
    [InlineData(2.0)]
    [InlineData(0.85)]
    public void UiScaleIsAppliedOnceByTheWindowNotAgainByTheChip(double scale)
    {
        // ThemeService lays the content out at window/scale and draws it scaled by `scale`. A 1200-wide window's reply
        // column (760 max, minus the 24 + 24 side insets the window takes) in layout units, then on screen.
        var window = 1200.0;
        var column = Math.Min(760, window / scale - 48);
        var onScreen = LinkChipFit.Width(column) * scale;
        Assert.Equal(Math.Min(column, 300) * scale, onScreen, 6);   // as the Mac's min(maxText, 300 * glyphScale)
        Assert.True(onScreen <= column * scale + 1e-9);
        // The chip itself never reads the scale.
        var src = Source(View);
        Assert.DoesNotContain("UiScale", src);
        Assert.DoesNotContain("State.Scale", src);
        Assert.DoesNotContain("RasterizationScale", src);
        Assert.DoesNotContain("Scale", Source("Hermes.Core/Transcript/LinkChipFit.cs").Split("public static double Width")[1]);
    }

    [Fact]
    public void TheViewSizesFromItsColumnNotAFixedWidth()
    {
        var src = Source(View);
        // No fixed Width: a narrower message column used to be ignored and the card ran past it.
        Assert.DoesNotMatch(new Regex(@"(?<![A-Za-z.])Width\s*=\s*MaxChipWidth"), src);
        Assert.DoesNotMatch(new Regex(@"^\s*Width\s*=", RegexOptions.Multiline), src);
        Assert.Contains("public const double MaxChipWidth = LinkChipFit.MaxWidth;", src);
        // Measured from the room offered: LinkChipFit.Width of the available width, and the fixed height.
        var measure = Body(src, "Size MeasureOverride(");
        Assert.Contains("LinkChipFit.Width(available.Width)", measure);
        Assert.Contains("ChipHeight", measure);
        var arrange = Body(src, "Size ArrangeOverride(");
        Assert.Contains("ChipHeight", arrange);
        Assert.Contains("Height = ChipHeight", src);   // its height stays fixed from the start
    }

    [Fact]
    public void ALateTitleOrIconNeverChangesItsSize()
    {
        var src = Source(View);
        // Show() runs again when the synthetic/cached title and icon arrive: it sets words and the icon only.
        var show = Body(src, "void Show(");
        foreach (var size in new[] { "Width", "Height", "InvalidateMeasure", "MaxWidth", "MinWidth" })
            Assert.DoesNotMatch(new Regex(@"(?<![A-Za-z_])(this\.)?" + size + @"\s*=|" + size + @"\(\)"), Strip(show));
        // Its width depends on the room only: the title's length doesn't enter it.
        var measure = Body(src, "Size MeasureOverride(");
        Assert.DoesNotContain("_title", measure);
        Assert.DoesNotContain("_host", measure);
        Assert.Equal(LinkChipFit.Width(500), LinkChipFit.Width(500));
        // The title and host trim with an ellipsis in one line instead of widening the card.
        Assert.Equal(2, Regex.Matches(src, @"TextTrimming = TextTrimming\.CharacterEllipsis, TextWrapping = TextWrapping\.NoWrap").Count);
    }

    [Fact]
    public void LinkBehaviourIsUntouched()
    {
        var src = Source(View);
        Assert.Contains("Click += (_, _) => ChatLinks.Open(_url);", src);
        Assert.Contains("await LinkPreviews.Shared.PreviewAsync(_raw)", src);
        Assert.Contains("if (LinkTargets.Target(url).Kind is LinkTargetKind.Loopback or LinkTargetKind.Refused) return;", src);
    }

    // The image's icon size inside Show() names Width = IconSize on a new Image: that's the icon, not the chip.
    private static string Strip(string show) => Regex.Replace(show, @"new (Image|BitmapImage) \{[^}]*\}", "");

    private static string Body(string src, string marker)
    {
        var at = src.IndexOf(marker, StringComparison.Ordinal);
        Assert.True(at >= 0, "missing " + marker);
        var open = src.IndexOf('{', at);
        var depth = 0;
        for (var i = open; i < src.Length; i++)
        {
            if (src[i] == '{') depth++;
            else if (src[i] == '}' && --depth == 0) return src[open..(i + 1)];
        }
        throw new InvalidOperationException("unbalanced " + marker);
    }

    private static string Source(string relative)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", relative));
    }
}
