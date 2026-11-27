using System.Globalization;
using System.Text.RegularExpressions;
using Hermes.Core.Transcripts;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-LINK-CHIP-SCALE] A link chip's size under UI Scale and the text size, as the Mac's
/// (App/Chat/Cells/LinkChipView.swift at 93f984bb1): `iconSize` 18 on the Mac, `padH` 12, `padV` 10,
/// `height(style:)` = padV + body line + 2 + time line + padV (the chat style's line heights, which grow with the text
/// size), `width(maxText:)` = min(maxText, 300 × HQFont.glyphScale) (glyphScale is 1 on the Mac: its width and icon stay
/// put while its words grow), the host cut in the middle (`.byTruncatingMiddle`), the title at its tail.
///
/// On Windows UI Scale is one ScaleTransform over the window (ThemeService.ApplyScale), so the chip's layout numbers are
/// drawn × UI Scale once; Windows' text size (UISettings.TextScaleFactor) grows the words inside it, as the Mac's text
/// size does. Synthetic numbers and words only. Headless arithmetic and source coverage: the card on a real Windows
/// screen at these scales still needs a Windows run.
public class LinkChipSizeTests
{
    private const string View = "HermesHQ.Windows/Features/Transcript/LinkChipView.cs";

    [Fact]
    public void TheMacsMetrics()
    {
        Assert.Equal(18, LinkChipSize.IconSize);
        Assert.Equal(12, LinkChipSize.PadH);
        Assert.Equal(10, LinkChipSize.PadV);
        Assert.Equal(2, LinkChipSize.LineGap);
        Assert.Equal(8, LinkChipSize.IconGap);
        // At the default text size: the transcript's 14 / 21 body and 11 / 15 time lines, 58 tall as before.
        Assert.Equal(58, LinkChipSize.Height(1.0));
        Assert.Equal(21, LinkChipSize.TitleLine(1.0));
        Assert.Equal(15, LinkChipSize.HostLine(1.0));
    }

    [Theory]
    [InlineData(1.00, 21, 15, 58)]
    [InlineData(1.25, 27, 19, 68)]   // 26.25 → 27, 18.75 → 19, as the Mac's `.rounded(.up)` line heights
    [InlineData(1.50, 32, 23, 77)]
    [InlineData(2.25, 48, 34, 104)]  // Windows' largest text size
    public void ItsHeightFollowsTheTextSize(double textScale, double title, double host, double height)
    {
        Assert.Equal(title, LinkChipSize.TitleLine(textScale));
        Assert.Equal(host, LinkChipSize.HostLine(textScale));
        Assert.Equal(height, LinkChipSize.Height(textScale));
        // padV + body line + 2 + time line + padV.
        Assert.Equal(LinkChipSize.PadV + title + LinkChipSize.LineGap + host + LinkChipSize.PadV, height);
    }

    [Theory]
    [InlineData(double.NaN)]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(double.PositiveInfinity)]
    public void AnUnknownTextSizeIsTheDefault(double textScale) => Assert.Equal(58, LinkChipSize.Height(textScale));

    [Theory]
    [InlineData(1.0)]
    [InlineData(1.25)]
    [InlineData(1.5)]
    public void TheIconAndWidthStayTheMacsAsTheWordsGrow(double textScale)
    {
        // The Mac's glyphScale is 1: its 18 icon and 300 cap don't follow the text size; the words trim inside.
        var at = LinkChipSize.Layout(column: 760, uiScale: 1, textScale: textScale);
        Assert.Equal(18, at.Icon);
        Assert.Equal(300, at.Width);
        Assert.Equal(LinkChipSize.Height(textScale), at.Height);
    }

    [Fact]
    public void At100PercentUiScale()
    {
        var at = LinkChipSize.Layout(column: 760, uiScale: 1.0, textScale: 1.0);
        Assert.Equal(new ChipOnScreen(300, 58, 18, 250), at);
    }

    [Fact]
    public void At125PercentUiScaleTheWholeCardIsDrawnOnceLarger()
    {
        // A 1200-wide window at 125 %: its content is laid out 960 wide (minus the 48 of side insets), the reply column
        // still offers more than 300, so the card is 300 layout units, drawn 375 wide, its icon 22.5, its height 72.5.
        var column = Math.Min(760, 1200 / 1.25 - 48);
        var at = LinkChipSize.Layout(column, uiScale: 1.25, textScale: 1.0);
        Assert.Equal(375, at.Width, 6);
        Assert.Equal(72.5, at.Height, 6);
        Assert.Equal(22.5, at.Icon, 6);
        Assert.Equal(250 * 1.25, at.TextRoom, 6);
        // As the iPhone's min(maxText, 300 × glyphScale), never UI Scale twice.
        Assert.Equal(Math.Min(column * 1.25, 300 * 1.25), at.Width, 6);
    }

    [Theory]
    [InlineData(1.0, 220, 220, 58, 18, 170)]
    [InlineData(1.25, 220, 275, 72.5, 22.5, 212.5)]
    [InlineData(1.0, 40, 40, 58, 18, 0)]   // narrower than its icon and paddings: no room for words, never negative
    public void InANarrowColumnItTakesTheColumn(double ui, double column, double width, double height, double icon, double room)
    {
        var at = LinkChipSize.Layout(column, ui, textScale: 1.0);
        Assert.Equal(width, at.Width, 6);
        Assert.Equal(height, at.Height, 6);
        Assert.Equal(icon, at.Icon, 6);
        Assert.Equal(room, at.TextRoom, 6);
        Assert.True(at.Width <= column * ui + 1e-9);
    }

    [Theory]
    [InlineData(300, 250)]
    [InlineData(220, 170)]
    [InlineData(50, 0)]
    [InlineData(0, 0)]
    public void TheWordsGetTheRoomBesideTheIcon(double chip, double room) =>
        // bounds.width − (padH + iconSize + 8) − padH, as the Mac's layoutSubviews.
        Assert.Equal(room, LinkChipSize.TextRoom(chip));

    // A synthetic monospace measure: 7 units a character.
    private static double Mono(string s) => new StringInfo(s).LengthInTextElements * 7;

    [Fact]
    public void AHostThatFitsIsShownWhole()
    {
        Assert.Equal("example.com/notes", LinkChipSize.MiddleTrim("example.com/notes", 250, Mono));
        Assert.Equal("", LinkChipSize.MiddleTrim("", 250, Mono));
    }

    [Fact]
    public void ALongHostIsCutInTheMiddleAsTheMacs()
    {
        const string host = "docs.example.com/guides/getting-started/install";
        var cut = LinkChipSize.MiddleTrim(host, 140, Mono);
        Assert.True(Mono(cut) <= 140, cut);
        Assert.Equal(20, cut.Length);   // the most that fits: 19 characters and the "…"
        var parts = cut.Split('…');
        Assert.Equal(2, parts.Length);
        Assert.StartsWith(parts[0], host);
        Assert.EndsWith(parts[1], host);
        Assert.Equal("docs.examp", parts[0]);   // the host's start is kept (the odd one goes to the head)…
        Assert.Equal("d/install", parts[1]);    // …and the path's end
        Assert.True(Math.Abs(parts[0].Length - parts[1].Length) <= 1);
    }

    [Fact]
    public void ItNeverSplitsACharacterAndGivesUpCleanly()
    {
        const string host = "😀😀😀😀😀😀😀😀😀😀.example";
        var cut = LinkChipSize.MiddleTrim(host, 70, Mono);
        Assert.True(Mono(cut) <= 70);
        Assert.Equal(10, new StringInfo(cut).LengthInTextElements);   // 9 characters and the "…"
        Assert.False(HasLoneSurrogate(cut), cut);
        Assert.StartsWith("😀😀😀😀😀", cut);
        Assert.EndsWith("…mple", cut);
        Assert.Equal("…", LinkChipSize.MiddleTrim(host, 7, Mono));
        Assert.Equal("", LinkChipSize.MiddleTrim(host, 6, Mono));
        Assert.Equal("", LinkChipSize.MiddleTrim(host, 0, Mono));
    }

    private static bool HasLoneSurrogate(string s)
    {
        for (var i = 0; i < s.Length; i++)
        {
            if (char.IsHighSurrogate(s[i])) { if (i + 1 >= s.Length || !char.IsLowSurrogate(s[i + 1])) return true; i++; }
            else if (char.IsLowSurrogate(s[i])) return true;
        }
        return false;
    }

    [Fact]
    public void TheViewTakesItsHeightAndLinesFromTheTextSize()
    {
        var src = Source(View);
        Assert.Contains("TextScaleFactorChanged", src);
        Assert.Contains("LinkChipSize.Height(_textScale)", src);
        Assert.Contains("LinkChipSize.TitleLine(_textScale)", src);
        Assert.Contains("LinkChipSize.HostLine(_textScale)", src);
        // The fixed 58 is gone: no const height.
        Assert.DoesNotMatch(new Regex(@"const double ChipHeight"), src);
        // The icon stays the Mac's 18 and the cap its 300; neither reads the text size.
        Assert.Contains("public const double IconSize = LinkChipSize.IconSize;", src);
        Assert.Contains("public const double MaxChipWidth = LinkChipFit.MaxWidth;", src);
    }

    [Fact]
    public void TheViewCutsTheHostInTheMiddleAndNamesItWhole()
    {
        var src = Source(View);
        Assert.Contains("LinkChipSize.MiddleTrim(", src);
        Assert.Contains("LinkChipSize.TextRoom(", src);
        // The spoken name keeps the whole host (LinkChips.Face), whatever the line shows.
        Assert.Contains("AutomationProperties.SetName(this, face.AccessibleName);", src);
        // The host the line shows comes from the whole one, not from the line's own (already cut) text.
        Assert.DoesNotContain("MiddleTrim(_host.Text", src);
    }

    private static string Source(string relative)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", relative)).Replace("\r\n", "\n");
    }
}
