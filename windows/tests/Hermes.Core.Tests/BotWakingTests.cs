// [WIN-BOT-WAKING] A bot row says "Waking up…" once its chat has been opening for a second, and stops the moment the open
// ends (bound, failed, or the chat was left). As the Mac at 93f984bb1: HermesKit/Store/BotStore+RowStatus.swift
// (`noteBotOpening`, `isWaking`), HermesKit/Store/BotStore.swift (`wakingGrace`, `input.waking = wakingBots`, `stop()`),
// App/AppModel.swift (`chat(for:)` sets it, `chatOpened`/`chatLeft` clear it), App/Bots/BotListModel.swift `rowStatus`.
// Ported case for case from Tests/BotsList/BotsListTests.swift (wakingShowsOnlyAfterTheGraceAndEndsWithTheOpen, the
// waking steps of rowStatusOrder) on the store's own rows; the rest state the Swift's guards and `stop()`. The Mac's
// `Task.sleep` grace is a manual clock here (Voice/MemoRecorderTests.cs ManualTime): no sleeps. Synthetic data only.
using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Tests.Voice;

namespace Hermes.Core.Tests;

public class BotWakingTests
{
    private static (BotStore Store, ManualTime Clock) Bots()
    {
        var clock = new ManualTime();
        var store = new BotStore(new FakeGateway(), new MemoryDeviceStore()) { WakingClock = clock };
        store.ApplyFull(new JsonObject
        {
            ["profiles"] = new JsonArray
            {
                new JsonObject { ["name"] = "ivy", ["canonical_session"] = new JsonObject { ["id"] = "reg", ["title"] = "Bot Chat", ["preview"] = "see you at noon", ["last_active"] = 1_791_000_000.0, ["message_count"] = 4.0 } },
                new JsonObject { ["name"] = "wren" },
            },
        }, DateTimeOffset.UtcNow);
        return (store, clock);
    }

    // MARK: BotsListTests.swift — wakingShowsOnlyAfterTheGraceAndEndsWithTheOpen

    [Fact]
    public void WakingShowsOnlyAfterTheGraceAndEndsWithTheOpen()
    {
        var (store, clock) = Bots();
        store.WakingGrace = TimeSpan.FromMilliseconds(150);
        store.NoteBotOpening("ivy", true);
        Assert.False(store.Bot("ivy")!.Waking);               // a fast open never says it
        store.NoteBotOpening("ivy", false);
        clock.Advance(TimeSpan.FromMilliseconds(300));
        Assert.False(store.Bot("ivy")!.Waking);

        store.NoteBotOpening("ivy", true);
        clock.Advance(TimeSpan.FromMilliseconds(150));
        Assert.True(store.Bot("ivy")!.Waking);
        Assert.True(store.IsWaking("ivy"));
        store.NoteBotOpening("ivy", false);
        Assert.False(store.Bot("ivy")!.Waking);
        Assert.False(store.IsWaking("ivy"));
        Assert.Equal(0, clock.Pending);
    }

    [Fact]
    public void TheGraceIsOneSecond()
    {
        var (store, clock) = Bots();
        Assert.Equal(TimeSpan.FromSeconds(1), store.WakingGrace);
        store.NoteBotOpening("ivy", true);
        clock.Advance(TimeSpan.FromMilliseconds(999));
        Assert.False(store.Bot("ivy")!.Waking);
        Assert.Equal("see you at noon", BotList.SecondLine(store.Bot("ivy")!).Text);
        clock.Advance(TimeSpan.FromMilliseconds(1));
        var ivy = store.Bot("ivy")!;
        Assert.True(ivy.Waking);
        Assert.Equal(BotList.RowStatus.Waking, BotList.StatusOf(ivy));
        Assert.Equal("Waking up…", BotList.SecondLine(ivy).Text);
        Assert.Equal(BotList.Tone.Secondary, BotList.SecondLine(ivy).Tone);
        Assert.False(store.Bot("wren")!.Waking);              // only the bot whose chat is opening
    }

    /// `guard wakingTasks[profile] == nil, !wakingBots.contains(profile)`: a second open of the same chat neither restarts
    /// the grace nor redraws a row already waking.
    [Fact]
    public void AnOpenAlreadyWaitingIsNotStartedAgain()
    {
        var (store, clock) = Bots();
        store.NoteBotOpening("ivy", true);
        clock.Advance(TimeSpan.FromMilliseconds(600));
        store.NoteBotOpening("ivy", true);
        Assert.Equal(1, clock.Pending);
        clock.Advance(TimeSpan.FromMilliseconds(400));         // the first grace, not a second one started at 600 ms
        Assert.True(store.IsWaking("ivy"));
        var raised = 0;
        store.Changed += () => raised++;
        store.NoteBotOpening("ivy", true);
        Assert.Equal(0, clock.Pending);
        Assert.Equal(0, raised);
        store.NoteBotOpening("wren", false);                    // an open that never began ends without a redraw
        Assert.Equal(0, raised);
        store.NoteBotOpening("ivy", false);
        Assert.Equal(1, raised);
    }

    /// A grace that ran out after its open ended (the Mac's `guard !Task.isCancelled`) draws nothing.
    [Fact]
    public void AGraceFiringAfterTheOpenEndedDrawsNothing()
    {
        var (store, clock) = Bots();
        var raised = 0;
        store.Changed += () => raised++;
        store.NoteBotOpening("ivy", true);
        store.NoteBotOpening("ivy", false);
        Assert.Equal(0, clock.Pending);
        clock.Advance(TimeSpan.FromSeconds(5));
        Assert.Equal(0, raised);
        Assert.False(store.IsWaking("ivy"));
    }

    // MARK: BotsListTests.swift — the waking steps of rowStatusOrder, on the store's own row

    [Fact]
    public void WakingOutranksWorkingAndAStandingProblemComesBackAfter()
    {
        var (store, clock) = Bots();
        store.SetWorkingChats("ivy", new HashSet<string> { "reg" });
        Assert.Equal(BotList.RowStatus.Working, BotList.StatusOf(store.Bot("ivy")!));
        store.NoteBotOpening("ivy", true);
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(BotList.RowStatus.Waking, BotList.StatusOf(store.Bot("ivy")!));
        Assert.Equal("Waking up…", BotList.SecondLine(store.Bot("ivy")!).Text);
        // While the chat is opening the row says so, and the problem comes back after.
        store.NoteTurnFailed("ivy", "No LLM provider configured");
        Assert.Equal(BotList.RowStatus.Waking, BotList.StatusOf(store.Bot("ivy")!));
        store.NoteBotOpening("ivy", false);
        var ivy = store.Bot("ivy")!;
        Assert.Equal(BotList.RowStatus.Attention, BotList.StatusOf(ivy));
        Assert.Equal("Provider not set up", BotList.SecondLine(ivy).Text);
        Assert.Equal(BotList.Tone.Attention, BotList.SecondLine(ivy).Tone);
    }

    /// `rowStatus`: waking comes before waiting for the person (`needsInput`), which comes back when the open ends.
    [Fact]
    public void WakingOutranksWaitingForYou()
    {
        var (store, clock) = Bots();
        store.SetLive(new HashSet<string>(), new HashSet<string> { "reg" });
        Assert.Equal(BotList.RowStatus.NeedsInput, BotList.StatusOf(store.Bot("ivy")!));
        store.NoteBotOpening("ivy", true);
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(BotList.RowStatus.Waking, BotList.StatusOf(store.Bot("ivy")!));
        store.NoteBotOpening("ivy", false);
        Assert.Equal(BotList.RowStatus.NeedsInput, BotList.StatusOf(store.Bot("ivy")!));
        Assert.Equal("Waiting for you", BotList.SecondLine(store.Bot("ivy")!).Text);
    }

    // MARK: BotStore.swift stop() — the waking half

    [Fact]
    public void StoppingTheStoreEndsEveryWait()
    {
        var (store, clock) = Bots();
        store.NoteBotOpening("ivy", true);
        clock.Advance(TimeSpan.FromSeconds(1));
        store.NoteBotOpening("wren", true);
        Assert.True(store.IsWaking("ivy"));
        store.StopWaking();
        Assert.False(store.IsWaking("ivy"));
        Assert.False(store.Bot("ivy")!.Waking);
        Assert.Equal(0, clock.Pending);
        clock.Advance(TimeSpan.FromSeconds(5));
        Assert.False(store.IsWaking("wren"));
    }

    /// Display only: the wait is never saved with the rows.
    [Fact]
    public void WakingIsNeverSaved()
    {
        var disk = new MemoryDeviceStore();
        var clock = new ManualTime();
        var store = new BotStore(new FakeGateway(), disk) { WakingClock = clock };
        store.ApplyFull(new JsonObject { ["profiles"] = new JsonArray { new JsonObject { ["name"] = "ivy" } } }, DateTimeOffset.UtcNow);
        store.NoteBotOpening("ivy", true);
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.True(store.Bot("ivy")!.Waking);
        var again = new BotStore(new FakeGateway(), disk);
        Assert.False(again.Bot("ivy")!.Waking);
    }
}
