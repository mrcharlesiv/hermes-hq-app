using System.Globalization;
using Hermes.Core.Groups;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-57] A room's moving typing dots (App/Chat/Cells/ChatCells.swift ChatWaitingCell `animate`) and its Activity
/// sheet (App/Groups/GroupInfoSheet.swift GroupActivityView).
public class GroupActivityTests
{
    // ------------------------------------------------------------------ the typing dots

    [Fact]
    public void TheDotsBrightenInTurnEveryOnePointTwoSecondsAFifthOfASecondApart()
    {
        // `let period: CFTimeInterval = 1.2`; dot n's offset is `fmod(now - n * 0.2 + period, period)`.
        Assert.Equal(3, TypingDots.Count);
        Assert.Equal(1.2, TypingDots.Period);
        Assert.Equal(0.2, TypingDots.Stagger);
        Assert.Equal([(0.0, 0.3), (0.25, 1.0), (0.5, 0.3), (1.0, 0.3)], TypingDots.Keys);
        Assert.Equal([TypingDots.Curve.EaseInEaseOut, TypingDots.Curve.EaseInEaseOut, TypingDots.Curve.Linear], TypingDots.Curves);
        Assert.Equal(0.0, TypingDots.Offset(0, 0), 9);
        Assert.Equal(1.0, TypingDots.Offset(1, 0), 9);   // 0 - 0.2 + 1.2
        Assert.Equal(0.8, TypingDots.Offset(2, 0), 9);
        Assert.Equal(0.1, TypingDots.Offset(0, 12.1), 9);   // one shared clock: the wave doesn't restart per row
        Assert.Equal(TypingDots.Offset(1, 5.0), TypingDots.Offset(1, 6.2), 9);
    }

    [Fact]
    public void ADotPeaksAQuarterOfThePeriodInAndRestsAtThirtyPercentForTheSecondHalf()
    {
        Assert.Equal(0.3, TypingDots.Opacity(0, 0, animationsEnabled: true), 6);
        Assert.Equal(1.0, TypingDots.Opacity(0, 0.3, animationsEnabled: true), 6);     // 0.25 of 1.2 s
        Assert.Equal(0.3, TypingDots.Opacity(0, 0.6, animationsEnabled: true), 6);
        Assert.Equal(0.3, TypingDots.Opacity(0, 0.9, animationsEnabled: true), 6);
        Assert.Equal(0.65, TypingDots.Opacity(0, 0.15, animationsEnabled: true), 6);   // ease-in-ease-out is symmetric
        Assert.InRange(TypingDots.Opacity(0, 0.05, animationsEnabled: true), 0.3, 0.4);   // slow out of the rest
        // The second dot is 0.2 s behind the first: its peak comes at 0.5 s.
        Assert.Equal(1.0, TypingDots.Opacity(1, 0.5, animationsEnabled: true), 6);
        Assert.Equal(1.0, TypingDots.Opacity(2, 0.7, animationsEnabled: true), 6);
    }

    [Fact]
    public void ReducedMotionKeepsTheDotsStillAtSixtyPercent()
    {
        // `guard !HQMotion.reduced else { … dot.alpha = 0.6 }`; on Windows, UISettings.AnimationsEnabled off.
        Assert.True(TypingDots.Animates(animationsEnabled: true));
        Assert.False(TypingDots.Animates(animationsEnabled: false));
        Assert.Equal(0.6, TypingDots.StillOpacity);
        foreach (var t in new[] { 0, 0.3, 0.77, 5.5 })
            for (var n = 0; n < TypingDots.Count; n++)
                Assert.Equal(0.6, TypingDots.Opacity(n, t, animationsEnabled: false));
    }

    [Fact]
    public void TheEaseIsCoreAnimationsEaseInEaseOutCurve()
    {
        Assert.Equal((0.42, 0.0, 0.58, 1.0), TypingDots.EaseInEaseOut);
        Assert.Equal(0.0, TypingDots.Ease(0), 9);
        Assert.Equal(1.0, TypingDots.Ease(1), 9);
        Assert.Equal(0.5, TypingDots.Ease(0.5), 6);
        Assert.True(TypingDots.Ease(0.1) < 0.1 && TypingDots.Ease(0.9) > 0.9);
    }

    // ------------------------------------------------------------------ the Activity sheet

    private static GroupActivityEvent E(GroupActivityKind kind, string member, double atMs, string? detail = null) => new(kind, member, detail, atMs, 1);

    private static readonly double T0 = new DateTimeOffset(2026, 11, 20, 15, 4, 0, TimeSpan.Zero).ToUnixTimeMilliseconds();

    [Fact]
    public void TheSheetIsTitledActivityAndSaysSoWhenTheTurnHasNothing()
    {
        Assert.Equal("Activity", GroupActivitySheet.Title);
        Assert.Equal("No activity in this turn yet.", GroupActivitySheet.Empty);
        Assert.Equal("group-activity.list", GroupActivitySheet.ListId);
        Assert.Equal("group-activity.empty", GroupActivitySheet.EmptyId);
        Assert.Equal("group-activity.row.2", GroupActivitySheet.RowId(2));
        Assert.Empty(GroupActivitySheet.Rows([], new Dictionary<string, string>(), TimeZoneInfo.Utc, CultureInfo.GetCultureInfo("en-US")));
    }

    [Fact]
    public void RowsAreNewestFirstWithTheMembersNameItsSymbolAndTheTime()
    {
        var events = new[]
        {
            E(GroupActivityKind.Queued, "", T0),
            E(GroupActivityKind.Working, "ivy", T0 + 1000),
            E(GroupActivityKind.Replied, "ivy", T0 + 61_000),
            E(GroupActivityKind.Failed, "research", T0 + 62_000, "no-slot"),
            E(GroupActivityKind.Stopped, "", T0 + 63_000),
        };
        var labels = new Dictionary<string, string> { ["ivy"] = "Ivy" };   // research isn't labelled: its key stands in
        var rows = GroupActivitySheet.Rows(events, labels, TimeZoneInfo.Utc, CultureInfo.GetCultureInfo("en-US"));
        Assert.Equal(
            ["You stopped the room — remaining turns are held until resumed", "research couldn't start — too many bots running",
             "Ivy replied", "Ivy is working…", "You sent a message"],
            rows.Select(r => r.Text));
        Assert.Equal(["stop", "exclamationmark.circle", "checkmark", "arrow.triangle.2.circlepath", "bubble.left"], rows.Select(r => r.Symbol));
        Assert.Equal([false, true, false, false, false], rows.Select(r => r.Red));
        Assert.Equal(["3:05 PM", "3:05 PM", "3:05 PM", "3:04 PM", "3:04 PM"], rows.Select(r => r.Time));
        Assert.All(rows, r => Assert.NotEqual("", r.Glyph));
        Assert.Equal("Ivy replied, 3:05 PM", rows[2].AccessibleName);   // .accessibilityElement(children: .combine)
    }

    [Fact]
    public void TheTimeIsTheLocalShortTime()
    {
        var zone = TimeZoneInfo.CreateCustomTimeZone("hqw-test", TimeSpan.FromHours(-6), "hqw-test", "hqw-test");
        var rows = GroupActivitySheet.Rows([E(GroupActivityKind.Settled, "", T0)], new Dictionary<string, string>(), zone, CultureInfo.GetCultureInfo("en-US"));
        Assert.Equal("9:04 AM", rows.Single().Time);
        Assert.Equal("Turn settled", rows.Single().Text);
        Assert.Equal("09:04", GroupActivitySheet.Rows([E(GroupActivityKind.Settled, "", T0)], new Dictionary<string, string>(), zone, CultureInfo.GetCultureInfo("de-DE")).Single().Time);
    }

    [Fact]
    public void EverySymbolHasAGlyph()
    {
        foreach (var kind in Enum.GetValues<GroupActivityKind>())
            Assert.NotEqual("", GroupActivitySheet.Glyph(GroupRowWords.Activity(E(kind, "ivy", T0), "Ivy").Symbol));
        Assert.Equal("", GroupActivitySheet.Glyph("no.such.symbol"));
    }

    // ------------------------------------------------------------------ the walk's checks

    [Fact]
    public void TheWalkChecksTheRoomsMenuItsActivityItsEmptyRoomAndTheMovingDots()
    {
        Assert.Null(GroupActivityWalkProof.Menu(["room.more.find", "room.more.info", "room.more.add", "room.more.activity", "room.more.delete"]));
        Assert.NotNull(GroupActivityWalkProof.Menu(["room.more.find", "room.more.info"]));

        var shown = new List<(string Text, string Time)> { ("Turn settled", "3:05 PM"), ("Research replied", "3:05 PM"), ("Ivy replied", "3:05 PM"), ("You sent a message", "3:04 PM") };
        Assert.Null(GroupActivityWalkProof.Activity("Activity", shown, emptyShown: false));
        Assert.NotNull(GroupActivityWalkProof.Activity("Activity", [.. shown.AsEnumerable().Reverse()], emptyShown: false));   // oldest first
        Assert.NotNull(GroupActivityWalkProof.Activity("Activity", [], emptyShown: true));
        Assert.NotNull(GroupActivityWalkProof.Activity("Room Activity", shown, emptyShown: false));
        Assert.NotNull(GroupActivityWalkProof.Activity("Activity", [("Turn settled", "")], emptyShown: false));

        Assert.Null(GroupActivityWalkProof.EmptyActivity("Activity", [], emptyText: "No activity in this turn yet."));
        Assert.NotNull(GroupActivityWalkProof.EmptyActivity("Activity", [], emptyText: "No Activity"));

        Assert.Null(GroupActivityWalkProof.EmptyRoom(true, "Quiet Room", "Ivy, Research", GroupRoomChrome.EmptyHint));
        Assert.NotNull(GroupActivityWalkProof.EmptyRoom(false, "Quiet Room", "Ivy, Research", GroupRoomChrome.EmptyHint));
        Assert.NotNull(GroupActivityWalkProof.EmptyRoom(true, "Quiet Room", "No bots yet", GroupRoomChrome.EmptyHint));

        // The dots move when animations are on: every dot's clock runs and advances between two looks.
        Assert.Null(GroupActivityWalkProof.DotsMoving(true, running: [true, true, true], before: [0.1, 0.3, 0.5], after: [0.6, 0.8, 1.0]));
        Assert.NotNull(GroupActivityWalkProof.DotsMoving(true, running: [true, false, true], before: [0.1, 0.3, 0.5], after: [0.6, 0.8, 1.0]));
        Assert.NotNull(GroupActivityWalkProof.DotsMoving(true, running: [true, true, true], before: [0.1, 0.3, 0.5], after: [0.1, 0.3, 0.5]));
        Assert.NotNull(GroupActivityWalkProof.DotsMoving(true, running: [], before: [], after: []));
        // Animations off (a CI desktop may say so): the dots are still, none running.
        Assert.Null(GroupActivityWalkProof.DotsMoving(false, running: [false, false, false], before: [0, 0, 0], after: [0, 0, 0]));
        Assert.NotNull(GroupActivityWalkProof.DotsMoving(false, running: [true, true, true], before: [0, 0, 0], after: [1, 1, 1]));
    }
}
