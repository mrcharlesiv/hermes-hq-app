using System.Text.RegularExpressions;
using Hermes.Core.Groups;
using Xunit;
using Part = Hermes.Core.Groups.RoomEmptyFit.Part;

namespace Hermes.Core.Tests;

/// [WIN-GROUP-EMPTY-FIT] An empty room fitted to the transcript's room, as the Mac's RoomEmptyView `layoutSubviews`
/// (App/Groups/GroupRoomChrome.swift at 93f984bb1) inside ChatViewController's `layoutEmpty(in: transcriptRoom)`.
/// Synthetic heights only (effective pixels): the name 27, the members 18, the hint 16 at the default text size.
public class GroupRoomEmptyFitTests
{
    private const double Name = 27, Members = 18, Hint = 16;
    /// 56 + 12 + 27 + 6 + 18 + 10 + 16: everything at the default text size.
    private const double Whole = 145;

    [Fact]
    public void TheMacsNumbersAndOrder()
    {
        Assert.Equal(320, RoomEmptyFit.MaxColumn);
        Assert.Equal(32, RoomEmptyFit.Side);
        Assert.Equal(56, RoomEmptyFit.AvatarSide);
        Assert.Equal(20, RoomEmptyFit.Lift);
        Assert.Equal(12, RoomEmptyFit.After(Part.Avatar));
        Assert.Equal(6, RoomEmptyFit.After(Part.Name));
        Assert.Equal(10, RoomEmptyFit.After(Part.Members));
        Assert.Equal([Part.Avatar, Part.Name, Part.Members, Part.Hint], RoomEmptyFit.Order);
        Assert.Equal([Part.Avatar, Part.Hint, Part.Members], RoomEmptyFit.Squeeze);   // the name stays
    }

    [Fact]
    public void TheWordsAreTheMacs()
    {
        Assert.Equal(("Launch Room", "Ivy, Research", "Everyone here sees what you send. Type @ to ask one bot."),
            RoomEmptyFit.Words("Launch Room", ["Ivy", "Research"]));
        Assert.Equal("No bots yet", RoomEmptyFit.Words("Quiet Room", []).Members);
    }

    [Theory]
    [InlineData(1000, 320)]
    [InlineData(384, 320)]
    [InlineData(300, 236)]
    [InlineData(50, 0)]   // never a negative column
    public void TheColumnIsAtMost320With32EitherSide(double width, double column) => Assert.Equal(column, RoomEmptyFit.Column(width));

    [Fact]
    public void ANormalRoomShowsEverythingCentredTwentyHigh()
    {
        var fit = RoomEmptyFit.Fit(800, 600, Name, Members, Hint);
        Assert.Equal([Part.Avatar, Part.Name, Part.Members, Part.Hint], fit.Shown);
        Assert.Equal(Whole, fit.Height);
        Assert.Equal(208, fit.Top);   // (600 - 145) / 2 - 20 = 207.5, rounded as Swift does: away from zero
        Assert.Equal(0, fit.GapAbove(Part.Avatar));
        Assert.Equal(12, fit.GapAbove(Part.Name));
        Assert.Equal(6, fit.GapAbove(Part.Members));
        Assert.Equal(10, fit.GapAbove(Part.Hint));
        Assert.False(fit.Clips);
        Assert.Equal(320, fit.Column);
        Assert.Equal(207, RoomEmptyFit.Fit(800, 598, Name, Members, Hint).Top);   // 206.5 → 207, not the banker's 206
    }

    [Fact]
    public void ExactlyEnoughRoomKeepsEverything()
    {
        var fit = RoomEmptyFit.Fit(800, Whole, Name, Members, Hint);
        Assert.Equal(4, fit.Shown.Count);
        Assert.Equal(0, fit.Top);   // (145 - 145) / 2 - 20 is above the room: it starts at the room's top
        Assert.False(fit.Clips);
    }

    [Fact]
    public void AShortRoomLeavesOutTheAvatarFirst()
    {
        var fit = RoomEmptyFit.Fit(800, 100, Name, Members, Hint);   // 145 > 100; 27 + 6 + 18 + 10 + 16 = 77
        Assert.Equal([Part.Name, Part.Members, Part.Hint], fit.Shown);
        Assert.Equal(77, fit.Height);
        Assert.Equal(0, fit.GapAbove(Part.Name));   // the avatar took its 12 with it
        Assert.Equal(0, fit.Top);                    // (100 - 77) / 2 - 20 = -8.5: never above the room
        Assert.False(fit.Clips);
        Assert.Equal(12, RoomEmptyFit.Fit(800, 141, Name, Members, Hint).Top);   // (141 - 77) / 2 - 20
    }

    [Fact]
    public void AShorterRoomLeavesOutTheHintThenTheMembers()
    {
        var hintOut = RoomEmptyFit.Fit(800, 60, Name, Members, Hint);   // 77 > 60; 27 + 6 + 18 = 51
        Assert.Equal([Part.Name, Part.Members], hintOut.Shown);
        Assert.Equal(51, hintOut.Height);   // the members are last: no 10 after them
        Assert.False(hintOut.Clips);

        var nameOnly = RoomEmptyFit.Fit(800, 40, Name, Members, Hint);
        Assert.Equal([Part.Name], nameOnly.Shown);
        Assert.Equal(27, nameOnly.Height);
        Assert.False(nameOnly.Clips);
    }

    [Theory]
    [InlineData(20)]
    [InlineData(0)]
    [InlineData(-5)]
    public void AnExtremelyShortRoomKeepsTheNameAndCutsItOff(double height)
    {
        var fit = RoomEmptyFit.Fit(800, height, Name, Members, Hint);
        Assert.Equal([Part.Name], fit.Shown);
        Assert.True(fit.Clips);   // drawn only inside the room, never under the composer
        Assert.Equal(0, fit.Top);
    }

    [Fact]
    public void ARoomMadeTallerAgainGetsEverythingBack()
    {
        // The fit is made afresh from the room each time (every part shown, then squeezed): nothing stays left out.
        var heights = new[] { 600.0, 100, 60, 20, 60, 100, 600 };
        var shown = heights.Select(h => RoomEmptyFit.Fit(800, h, Name, Members, Hint).Shown.Count).ToArray();
        Assert.Equal([4, 3, 2, 1, 2, 3, 4], shown);
        Assert.Equal(RoomEmptyFit.Fit(800, 600, Name, Members, Hint).Top, 208);
    }

    [Fact]
    public void LargerTextIsMeasuredOnceAndSqueezesSooner()
    {
        // Windows' Text size 225 % (UISettings.TextScaleFactor 2.25, the Mac's largest Dynamic Type): WinUI hands the
        // heights already scaled. The fit adds no scale of its own: the avatar stays 56, the gaps stay 12 / 6 / 10.
        double big(double h) => Math.Ceiling(h * 2.25);
        var all = RoomEmptyFit.Fit(800, 600, big(Name), big(Members), big(Hint));
        Assert.Equal(4, all.Shown.Count);
        Assert.Equal(56 + 12 + big(Name) + 6 + big(Members) + 10 + big(Hint), all.Height);

        Assert.Equal(4, RoomEmptyFit.Fit(800, 150, Name, Members, Hint).Shown.Count);
        // 61 + 6 + 41 + 10 + 36 = 154 without the avatar: at 150 the hint goes too, at 160 it stays.
        Assert.Equal([Part.Name, Part.Members], RoomEmptyFit.Fit(800, 150, big(Name), big(Members), big(Hint)).Shown);
        Assert.Equal([Part.Name, Part.Members, Part.Hint], RoomEmptyFit.Fit(800, 160, big(Name), big(Members), big(Hint)).Shown);
        Assert.Equal([Part.Name], RoomEmptyFit.Fit(800, 100, big(Name), big(Members), big(Hint)).Shown);
        Assert.True(RoomEmptyFit.Fit(800, 50, big(Name), big(Members), big(Hint)).Clips);
    }

    [Fact]
    public void FractionalHeightsRoundTheColumnUp()
    {
        var fit = RoomEmptyFit.Fit(800, 600, 26.6, 17.9, 15.95);
        Assert.Equal(Math.Ceiling(56 + 12 + 26.6 + 6 + 17.9 + 10 + 15.95), fit.Height);
    }

    // ------------------------------------------------------------------ the page (source: WinUI can't run here)

    private static string Page()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Pages", "GroupRoomPage.cs"));
    }

    private static string Body(string source, string signature)
    {
        var m = Regex.Match(source, Regex.Escape(signature) + @"\s*\{(?<body>.*?)\n    \}", RegexOptions.Singleline);
        Assert.True(m.Success, signature + " not found");
        return m.Groups["body"].Value;
    }

    [Fact]
    public void ThePageFitsTheEmptyRoomOnEverySizeChange()
    {
        var page = Page();
        Assert.Contains("_emptyRoom.SizeChanged += (_, e) => LayoutEmpty(e.NewSize.Width, e.NewSize.Height);", page);
        Assert.Contains("Grid.SetRow(_emptyRoom, 1);", page);   // the transcript's room, above the composer's rows
        Assert.Contains("_ui.TextScaleFactorChanged +=", page);
        var show = Body(page, "private void ShowEmpty(GroupRoomSession session, IReadOnlyList<ChatMessage> messages)");
        Assert.Contains("LayoutEmpty(_emptyRoom.ActualWidth, _emptyRoom.ActualHeight);", show);
        Assert.Contains("RoomEmptyFit.Words(", show);
    }

    [Fact]
    public void ThePageShowsEveryPartAgainBeforeMeasuringAndScalesNothingItself()
    {
        var layout = Body(Page(), "private void LayoutEmpty(double width, double height)");
        Assert.Contains("RoomEmptyFit.Fit(width, height,", layout);
        Assert.Contains("text.Visibility = Visibility.Visible;", layout);   // a part left out is measured again
        Assert.Contains("view.Visibility = fit.Shows(part) ? Visibility.Visible : Visibility.Collapsed;", layout);
        Assert.Contains("fit.Clips ?", layout);
        Assert.DoesNotContain("TextScaleFactor", layout);   // WinUI already scaled the words: no second scale
        Assert.DoesNotContain("RasterizationScale", layout);   // effective pixels, not physical ones
    }

    [Fact]
    public void ARoomWithRowsOrTypingHasNothingOverIt()
    {
        var show = Body(Page(), "private void ShowEmpty(GroupRoomSession session, IReadOnlyList<ChatMessage> messages)");
        Assert.Contains("_emptyRoom.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;", show);
        Assert.Contains("_emptyRoom.Clip = null;", show);
        Assert.Contains("new() { Visibility = Visibility.Collapsed, IsHitTestVisible = false }", Page());
    }

    [Fact]
    public void TheEmptyRoomsAvatarFollowsTheRoomNotTheFirstOneDrawn()
    {
        var show = Body(Page(), "private void ShowEmpty(GroupRoomSession session, IReadOnlyList<ChatMessage> messages)");
        Assert.DoesNotContain("_emptyAvatar.Children.Count == 0", show);   // the stale check: drawn once, kept for good
        Assert.Contains("if (key != _emptyAvatarKey)", show);
        Assert.Contains("session.RoomKey", show);
        Assert.Contains("row.Image", show);
    }
}
