// [WIN-WAKING-SPINNER] "Waking up…" draws a small spinner: before the row's words, and in a pinned tile's badge place (the
// Windows rail's face, as MacBotsRail draws `BotAvatar(tile: true)`). As the Mac at 93f984bb1: App/Bots/BotRowViews.swift
// (`BotAvatar.body`'s corner: attention unless the working dots take it, waking, waiting, then `rowBadge`, then the unread
// dot; `bottomLine`'s spinner when `rowStatus == .waking`; `badgeSize`, `presenceSize`), App/Bots/BotListModel.swift
// (`tileShowsWorkingOverProblem`, `rowBadge`). Ported from Tests/Settings/WorkingRingTests.swift
// (aPinnedTileTryingAgainShowsItWorksOverItsProblem) and the waking steps of Tests/BotsList/BotsListTests.swift
// (rowStatusOrder); the rest state the Swift's corner order case for case. Synthetic data only.
using System.Text.Json.Nodes;
using Hermes.Core.Bots;

namespace Hermes.Core.Tests;

public class BotFaceBadgeTests
{
    private static BotRow Otto(bool working = false)
    {
        var p = RosterProfile.From(JsonNode.Parse("""{"name":"otto"}"""))!;
        return new BotRow { Id = "otto", Name = "Otto", Profile = p, Model = p.ToModel("Otto", new BotMeta()), IsWorking = working, Pinned = true };
    }

    // MARK: WorkingRingTests.swift — aPinnedTileTryingAgainShowsItWorksOverItsProblem

    [Fact]
    public void APinnedTileTryingAgainShowsItWorksOverItsProblem()
    {
        var bot = Otto(working: true) with { Attention = "Out of credits for this model" };
        var status = BotList.StatusOf(bot);
        Assert.Equal(BotList.RowStatus.Attention, status);          // the problem stays until a good reply
        Assert.True(BotList.TileShowsWorkingOverProblem(bot, status, ringOn: false));
        Assert.Equal(BotList.FaceBadge.Working, BotList.FaceBadgeOf(bot, tile: true, ringOn: false, presence: true));   // the dots it then shows
        Assert.False(BotList.TileShowsWorkingOverProblem(bot, status, ringOn: true));   // the ring says it
        Assert.Equal(BotList.FaceBadge.Attention, BotList.FaceBadgeOf(bot, tile: true, ringOn: true, presence: true));
        bot = bot with { IsWorking = false };
        Assert.False(BotList.TileShowsWorkingOverProblem(bot, BotList.StatusOf(bot), ringOn: false));   // idle: the orange badge
        Assert.Equal(BotList.FaceBadge.Attention, BotList.FaceBadgeOf(bot, tile: true, ringOn: false, presence: true));
    }

    // MARK: BotsListTests.swift — rowStatusOrder (waking), drawn

    [Fact]
    public void AWakingTileShowsTheSpinnerInItsBadgePlace()
    {
        var waking = Otto(working: true) with { Waking = true };
        Assert.Equal(BotList.RowStatus.Waking, BotList.StatusOf(waking));
        Assert.Equal(BotList.FaceBadge.Waking, BotList.FaceBadgeOf(waking, tile: true, ringOn: true, presence: true));
        Assert.Equal(BotList.FaceBadge.Waking, BotList.FaceBadgeOf(waking, tile: true, ringOn: false, presence: true));
        // Waking outranks a standing problem: the spinner, not the orange badge.
        var both = waking with { Attention = "Out of credits for this model", IsWorking = false };
        Assert.Equal(BotList.FaceBadge.Waking, BotList.FaceBadgeOf(both, tile: true, ringOn: true, presence: true));
        // And outranks waiting on the person.
        Assert.Equal(BotList.FaceBadge.Waking, BotList.FaceBadgeOf(both with { NeedsInput = "Waiting for you" }, tile: true, ringOn: true, presence: true));
    }

    [Fact]
    public void ARowsFaceNeverShowsTheTileOnlyBadges()
    {
        // A row (not a tile) has its second line: the face reads `.idle` there, so no spinner or orange badge on it.
        var waking = Otto() with { Waking = true };
        Assert.Equal(BotList.FaceBadge.None, BotList.FaceBadgeOf(waking, tile: false, ringOn: true, presence: true));
        var failed = Otto() with { Attention = "Out of credits for this model" };
        Assert.Equal(BotList.FaceBadge.None, BotList.FaceBadgeOf(failed, tile: false, ringOn: true, presence: true));
        var waiting = Otto() with { NeedsInput = "Waiting for you" };
        Assert.Equal(BotList.FaceBadge.None, BotList.FaceBadgeOf(waiting, tile: false, ringOn: true, presence: true));
        Assert.Equal(BotList.FaceBadge.Working, BotList.FaceBadgeOf(waking with { IsWorking = true }, tile: false, ringOn: true, presence: true));
        Assert.Equal(BotList.FaceBadge.Unread, BotList.FaceBadgeOf(Otto() with { Unread = true }, tile: false, ringOn: true, presence: true));
    }

    [Fact]
    public void TheTileCornerOrder()
    {
        Assert.Equal(BotList.FaceBadge.None, BotList.FaceBadgeOf(Otto(), tile: true, ringOn: true, presence: true));
        var waiting = Otto(working: true) with { NeedsInput = "Waiting for your approval" };
        Assert.Equal(BotList.FaceBadge.Waiting, BotList.FaceBadgeOf(waiting, tile: true, ringOn: true, presence: true));
        Assert.Equal(BotList.FaceBadge.Working, BotList.FaceBadgeOf(Otto(working: true), tile: true, ringOn: true, presence: true));
        // The unread dot only where the face carries presence, and never over the working dots.
        var unread = Otto() with { Unread = true };
        Assert.Equal(BotList.FaceBadge.Unread, BotList.FaceBadgeOf(unread, tile: true, ringOn: true, presence: true));
        Assert.Equal(BotList.FaceBadge.None, BotList.FaceBadgeOf(unread, tile: true, ringOn: true, presence: false));
        Assert.Equal(BotList.FaceBadge.Working, BotList.FaceBadgeOf(unread with { IsWorking = true }, tile: true, ringOn: true, presence: true));
    }

    [Fact]
    public void OnlyAWakingRowDrawsTheSpinnerBeforeItsWords()
    {
        var waking = Otto() with { Waking = true };
        Assert.True(BotList.RowShowsSpinner(waking));
        Assert.Equal("Waking up…", BotList.SecondLine(waking).Text);
        Assert.Null(BotList.SecondLine(waking).Prefix);                        // no preview lead while waking
        // The row's name still says it: the spinner is hidden from UI Automation, the words are not.
        Assert.Equal("Otto. Waking up… Pinned", BotList.AccessibilityLabel(waking, ""));
        Assert.True(BotList.RowShowsSpinner(waking with { Attention = "Out of credits for this model" }));
        Assert.False(BotList.RowShowsSpinner(Otto()));
        Assert.False(BotList.RowShowsSpinner(Otto(working: true)));
        Assert.False(BotList.RowShowsSpinner(Otto() with { Attention = "Out of credits for this model" }));
        Assert.False(BotList.RowShowsSpinner(Otto() with { NeedsInput = "Waiting for you" }));
    }

    [Fact]
    public void BadgeSizesAsTheMac()
    {
        // `clamp(14, 0.36 × head, 22)`: 20 on a 56 head; the rail's 34 face gets 14.
        Assert.Equal(20, BotList.BadgeSize(56));
        Assert.Equal(14, BotList.BadgeSize(34));
        Assert.Equal(22, BotList.BadgeSize(80));
        // `clamp(8, 0.24 × head, 16)`: 12 on a 50 head.
        Assert.Equal(12, BotList.PresenceSize(50));
        Assert.Equal(8, BotList.PresenceSize(20));
        Assert.Equal(16, BotList.PresenceSize(90));
    }
}
