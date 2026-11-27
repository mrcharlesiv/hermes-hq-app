// [WIN-THINKING-FACE] The thinking row's drawing: the bot's face, the 40×24 typing-dots capsule, the words and the
// timer, the pill on a chat background, the trimming that keeps the timer whole, and the shimmer's band. Ported from
// the Mac at 93f984bb1: App/Chat/Render/TextLayout.swift `WaitingLayout` and its `.waiting` case,
// App/Chat/Cells/ChatCells.swift `ChatWaitingCell` (`configure`, `tick`, `placePill`) and
// App/Chat/Activity/GlyphSpinner.swift `Shimmer`. The Mac has no unit test for these numbers (its only waiting-row
// test, ChatUITests `waitWords`, is ThinkingRowTests' Words/Elapsed); these pin the Swift's arithmetic.

using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

public class WaitingLayoutTests
{
    [Fact]
    public void TheBotsFaceLeadsTheCapsuleThenTheWords()
    {
        // style.notice ~ 16 pt line: the row is 30 tall, the face and capsule centred in it.
        var w = WaitingLayout.Make(width: 400, lineHeight: 16, gap: 4, lead: 16, bot: true, plain: false);
        Assert.Equal(34, w.Height);
        Assert.Equal(new WaitingRect(16, 7, 24, 24), w.Face);
        Assert.Equal(new WaitingRect(46, 7, 40, 24), w.Capsule);       // face, 6 pt, the capsule
        Assert.Equal(94, w.Text.X);                                    // the capsule, 8 pt, the words
        Assert.Equal(400 - 94 - 16, w.Text.Width);
        Assert.Equal(4 + (30 - 16) / 2.0, w.Text.Y);
    }

    [Fact]
    public void NoBotOrARoomsTypingRowHasNoFace()
    {
        var none = WaitingLayout.Make(width: 400, lineHeight: 16, gap: 0, lead: 16, bot: false, plain: false);
        Assert.Null(none.Face);
        Assert.Equal(16, none.Capsule.X);
        // [groups] A room's typing row leaves the face column free and draws no bot face.
        var room = WaitingLayout.Make(width: 400, lineHeight: 16, gap: 0, lead: 16, bot: true, plain: true, senderColumn: 34);
        Assert.Null(room.Face);
        Assert.Equal(50, room.Capsule.X);
    }

    [Fact]
    public void ABigTextSizeGrowsTheRow()
    {
        var w = WaitingLayout.Make(width: 400, lineHeight: 41, gap: 0, lead: 16, bot: true, plain: false);
        Assert.Equal(41, w.Height);
        Assert.Equal(9, w.Capsule.Y);   // ((41 - 24) / 2).rounded()
        Assert.Equal(0, WaitingLayout.Make(width: 50, lineHeight: 16, gap: 0, lead: 16, bot: true, plain: false).Text.Width);
    }

    [Fact]
    public void TheDotsSitCentredInTheCapsuleOr12InOnThePill()
    {
        Assert.Equal(6, WaitingLayout.DotsStart(40, pillInset: 0));    // (40 - (18 + 10)) / 2
        Assert.Equal(9, WaitingLayout.DotsStart(40, pillInset: 3));    // 12 - inset
        Assert.Equal(9, WaitingLayout.DotTop(24));
    }

    [Fact]
    public void TheWordsTrimBeforeTheTimerWhichShowsWhole()
    {
        // No timer for the first 10 s: the words take the whole room.
        Assert.Equal(0, WaitingLayout.Reserve(""));
        Assert.Equal(120, WaitingLayout.WordsWidth(room: 200, reserve: 0, natural: 120));
        Assert.Equal(200, WaitingLayout.WordsWidth(room: 200, reserve: 0, natural: 260));
        // From 10 s the timer's measured width and its 5 pt gap are kept; a long step's words end in "…" before it.
        var reserve = WaitingLayout.Reserve("· 1:15", 33.2);
        Assert.Equal(39, reserve);                                    // ceil(33.2) + 5
        Assert.Equal(161, WaitingLayout.WordsWidth(200, reserve, natural: 260));
        Assert.Equal(120, WaitingLayout.WordsWidth(200, reserve, natural: 120));
        Assert.Equal(0, WaitingLayout.WordsWidth(30, reserve, natural: 120));
        Assert.Equal(161 + 5, WaitingLayout.TimerX(wordsX: 0, wordsWidth: 161));
    }

    [Fact]
    public void ThePillLeavesTheWordsRoomForItsFarEnd()
    {
        Assert.Equal(290, WaitingLayout.Room(textWidth: 290, pillInset: 0));
        Assert.Equal(277, WaitingLayout.Room(textWidth: 290, pillInset: 3));   // - (3 + 10)
        Assert.Equal(0, WaitingLayout.Room(textWidth: 5, pillInset: 3));
        Assert.Equal(3, WaitingLayout.PillInset(backdrop: true));
        Assert.Equal(0, WaitingLayout.PillInset(backdrop: false));
    }

    [Fact]
    public void ThePillHoldsTheFaceTheDotsTheWordsAndTheTimer()
    {
        var capsule = new WaitingRect(49, 7, 40, 24);
        // From the face, 3 pt round, to 10 pt past the words.
        var pill = WaitingLayout.Pill(faceX: 19, capsule, wordsMaxX: 200, timerShown: false, timerMaxX: 0, lineHeight: 16.2);
        Assert.Equal(new WaitingRect(16, 4, 194, 30), pill);
        Assert.Equal(15, WaitingLayout.PillRadius(pill));
        // With the timer, to 10 pt past it; no face, from the capsule.
        var timed = WaitingLayout.Pill(faceX: null, capsule, wordsMaxX: 200, timerShown: true, timerMaxX: 240, lineHeight: 16);
        Assert.Equal(new WaitingRect(46, 4, 204, 30), timed);
        // A line taller than the capsule makes it taller.
        Assert.Equal(46, WaitingLayout.Pill(null, capsule, 200, false, 0, lineHeight: 39.5).Height);
    }

    [Fact]
    public void TheShimmersBandAndPassFollowTheDesktop()
    {
        // `4ch + 80px`; one pass (200 + band + 200·tan 15°) / 200 s, then a 100 ms rest.
        Assert.Equal(108, WaitingShimmer.Band(zeroWidth: 7));
        Assert.Equal((200 + 108 + 200 * Math.Tan(15 * Math.PI / 180)) / 200, WaitingShimmer.Pass(108), 9);
        Assert.Equal(WaitingShimmer.Pass(108) + 0.1, WaitingShimmer.Lap(108), 9);
        Assert.Equal(17, WaitingShimmer.Stops.Count);
        Assert.Equal(17, WaitingShimmer.Resting.Count);
        Assert.Equal(0, WaitingShimmer.Resting[8]);
        Assert.Equal(1, WaitingShimmer.Resting[0]);
    }

    [Fact]
    public void TheShimmerSweepsAcrossTheWords()
    {
        var s = WaitingShimmer.Sweep(width: 120, height: 16, band: 108);
        var slack = 8 * Math.Tan(15 * Math.PI / 180) + 1;
        Assert.Equal(slack, s.Slack, 9);
        Assert.Equal(120 + slack, s.Reach, 9);
        Assert.Equal(2 * s.Reach + 108 + 2 * slack, s.Width, 9);
        Assert.Equal(-slack - 108 - s.Reach - slack, s.From, 9);
        Assert.Equal(-slack, s.To, 9);
        // The band's centre at its middle stop.
        Assert.Equal((slack + s.Reach + 54) / s.Width, s.Locations[8], 9);
        Assert.All(s.Locations, l => Assert.InRange(l, 0, 1));
    }

    [Fact]
    public void LightFadesTheWordsDarkLightsThemUp()
    {
        // Light: the band fades the text to a fifth of its alpha. Dark: the primary label over the text, 1 - resting.
        Assert.Equal(0.2, WaitingShimmer.LightAlpha(0), 9);
        Assert.Equal(1, WaitingShimmer.LightAlpha(1), 9);
        Assert.Equal(0.6, WaitingShimmer.LightAlpha(0.5), 9);
        Assert.Equal(1, WaitingShimmer.DarkGlow(0), 9);
        Assert.Equal(0, WaitingShimmer.DarkGlow(1), 9);
    }

    [Fact]
    public void TheShimmerAndTheDotsStillUnderReducedAnimations()
    {
        Assert.True(WaitingShimmer.Runs(animationsEnabled: true, width: 120, height: 16));
        Assert.False(WaitingShimmer.Runs(animationsEnabled: false, width: 120, height: 16));
        Assert.False(WaitingShimmer.Runs(animationsEnabled: true, width: 0, height: 16));
    }

    [Fact]
    public void OneClockSoARedrawDoesntRestartThePass()
    {
        var lap = WaitingShimmer.Lap(108);
        Assert.Equal(WaitingShimmer.Offset(10.5, 108), WaitingShimmer.Offset(10.5 + 3 * lap, 108), 6);
        Assert.InRange(WaitingShimmer.Offset(1234.567, 108), 0, lap);
    }
}
