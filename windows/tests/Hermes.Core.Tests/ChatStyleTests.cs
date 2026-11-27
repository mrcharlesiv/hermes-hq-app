// [WIN-THINKING-TEXT-STYLE] The thinking row's words and timer in the Mac's `style.notice` (App/Chat/ChatStyle.swift,
// App/Theme/ThemeFonts.swift, HermesKit/Theme/ThemeState.swift, App/Chat/Cells/ChatCells.swift `ChatWaitingCell` at
// 93f984bb1). The Mac has no unit test for these sizes; these pin the Swift's arithmetic and the Catalyst line height
// measured on a Mac (UIFont.systemFont(ofSize:).lineHeight: 15 → 18, 16.5 → 19, 13 → 16, 17 → 20).

using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

public class ChatStyleTests
{
    [Fact]
    public void TheDesktopLooksNoticeIsTheDesktopsFootnoteOnTheMacBase()
    {
        // 12.5 × 1.3 = 16.25 → 16.5 on a half point; 12.705 on the screen at 77 %.
        Assert.Equal(16.5, ChatStyle.NoticePoints(desktopLook: true, uiScalePercent: 100, textScale: 1));
        var f = ChatStyle.Notice(desktopLook: true, uiScalePercent: 100, textScale: 1);
        Assert.Equal(16.5 * 0.77, f.FontSize, 6);
        Assert.Equal(19, f.MacLineHeight);
        Assert.Equal(19 * 0.77, f.LineHeight, 6);
        Assert.Equal(400, f.Weight);
    }

    [Fact]
    public void TheIOSLooksNoticeIsIOSsFootnoteOnItsMacBase()
    {
        // 13 × 1.15 = 14.95 → 15; 11.55 on the screen.
        Assert.Equal(15, ChatStyle.NoticePoints(desktopLook: false, uiScalePercent: 100, textScale: 1));
        var f = ChatStyle.Notice(desktopLook: false, uiScalePercent: 100, textScale: 1);
        Assert.Equal(11.55, f.FontSize, 6);
        Assert.Equal(18, f.MacLineHeight);
        Assert.Equal(18 * 0.77, f.LineHeight, 6);
    }

    [Theory]
    [InlineData(15, 18)]
    [InlineData(16.5, 19)]
    [InlineData(13, 16)]
    [InlineData(17, 20)]
    public void TheLineIsCatalystsSystemFontLine(double points, double line) =>
        Assert.Equal(line, ChatStyle.MacLineHeight(points));

    [Fact]
    public void UIScaleGrowsTheNoticeButNeverUnderTheMacsSmallest()
    {
        // 90 %: 12.5 × 1.17 = 14.625 → 14.5, lifted to 15. 150 %: 12.5 × 1.95 = 24.375 → 24.5.
        Assert.Equal(15, ChatStyle.NoticePoints(true, 90, 1));
        Assert.Equal(24.5, ChatStyle.NoticePoints(true, 150, 1));
        // iOS look 90 %: 13 × 1.035 = 13.455 → 13.5 (the iOS look has no 15 pt floor).
        Assert.Equal(13.5, ChatStyle.NoticePoints(false, 90, 1));
        Assert.Equal(22.5, ChatStyle.NoticePoints(false, 150, 1));   // 13 × 1.725 = 22.425
        // The window's transform scales it back: in layout units the size is the screen's over UI Scale.
        Assert.Equal(15 * 0.77 / 0.9, ChatStyle.Notice(true, 90, 1).FontSize, 6);
        Assert.Equal(24.5 * 0.77 / 1.5, ChatStyle.Notice(true, 150, 1).FontSize, 6);
    }

    [Theory]
    [InlineData(1.0, 3)]     // Large, the default
    [InlineData(1.1, 3)]     // under xLarge's 19/17
    [InlineData(1.12, 4)]    // xLarge
    [InlineData(1.5, 6)]     // xxxLarge (23/17)
    [InlineData(1.65, 7)]    // AX1 (28/17)
    [InlineData(2.25, 8)]    // Windows' largest: AX2 (33/17); AX3 is 40/17
    [InlineData(double.NaN, 3)]
    [InlineData(0, 3)]
    public void WindowsTextSizeStandsForADynamicTypeSize(double textScale, int category) =>
        Assert.Equal(category, ChatStyle.Category(textScale));

    [Fact]
    public void TheTextSizeGrowsTheLineAsTheMacsFootnoteGrows()
    {
        // AX1: Desktop Look 12.5 × 28/17 × 1.3 = 26.76 → 27; iOS look 23 × 1.15 = 26.45 → 26.5.
        Assert.Equal(27, ChatStyle.NoticePoints(true, 100, 1.65));
        Assert.Equal(26.5, ChatStyle.NoticePoints(false, 100, 1.65));
        var f = ChatStyle.Notice(true, 100, 1.65);
        // The font size stays the default's (WinUI grows it by the text size itself); the line is the Mac's at AX1.
        Assert.Equal(16.5 * 0.77, f.FontSize, 6);
        Assert.Equal(27, f.MacPoints);
        Assert.Equal(ChatStyle.MacLineHeight(27), f.MacLineHeight);
        Assert.Equal(f.MacLineHeight * 0.77, f.LineHeight, 6);
        // xxxLarge in the iOS look: 19 × 1.15 = 21.85 → 22.
        Assert.Equal(22, ChatStyle.NoticePoints(false, 100, 1.5));
    }

    [Fact]
    public void UIScaleTimesTheTextSizeStopsAtIOSsLargestText()
    {
        // AX5 at 150 %: 53/17 × 1.95 is over the cap, so 12.5 × 53/17 = 38.97 → 39.
        Assert.Equal(39, ChatStyle.NoticePoints(true, 150, 53.0 / 17));
        // iOS look: AX5's 44 × min(1.725, max(1, 1)) = 44.
        Assert.Equal(44, ChatStyle.NoticePoints(false, 150, 53.0 / 17));
    }

    [Fact]
    public void TheTimerKeepsSteadyDigitsUnlessASkinsTypefaceDrawsIt()
    {
        Assert.True(ChatStyle.TimerTabular(desktopLook: false, skinSansFamily: "Inter"));
        Assert.True(ChatStyle.TimerTabular(desktopLook: true, skinSansFamily: null));
        Assert.False(ChatStyle.TimerTabular(desktopLook: true, skinSansFamily: "Inter"));
        Assert.Null(ChatStyle.NoticeFamily(false, "Inter"));
        Assert.Equal("Inter", ChatStyle.NoticeFamily(true, "Inter"));
    }

    [Fact]
    public void TheMacsLineFeedsTheRow()
    {
        // The Desktop Look's 19 pt line sits under the 30 pt floor, centred on the capsule.
        var f = ChatStyle.Notice(true, 100, 1);
        var w = WaitingLayout.Make(width: 600, lineHeight: f.LineHeight, gap: 0, lead: 0, bot: true, plain: false);
        Assert.Equal(30, w.Height);
        Assert.Equal(Math.Ceiling(f.LineHeight), w.Text.Height);
    }
}
