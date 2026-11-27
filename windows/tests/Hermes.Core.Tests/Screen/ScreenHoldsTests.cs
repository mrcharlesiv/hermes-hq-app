// [WIN-SCREEN-WIRE-KEYS-MATH] Who held control, remembered (Hermes.Core/Screen/ScreenHolds.cs), ported case for case
// from the Mac's Tests/Screen/ScreenHoldsTests.swift at 93f984bb1 (docs/spec/3x-screen.md §5.8): the reclaim rule, the
// saved hold and its 24 hours, the leaving cases, the gateway's remembered kind. UserDefaults is Hermes.Core's
// IKeyValueStore (strings only), so the Swift "not a string" values (42, Data) are stored as their text and must be
// ignored and cleared the same way.

using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Screen;

namespace Hermes.Core.Tests.Screen;

public class ScreenHoldsTests
{
    private sealed class Clock { public DateTimeOffset Date = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000); }

    private static (ScreenHolds Holds, MemoryStore Defaults, Clock Clock) Make()
    {
        var defaults = new MemoryStore();
        var clock = new Clock();
        return (new ScreenHolds(defaults, () => clock.Date), defaults, clock);
    }

    private static ScreenViewer Viewer(string id) => new(id);
    private static ScreenLease Human(ScreenViewer viewer, long epoch = 3) => new(ScreenHolder.Human, viewer.Hash, epoch);

    [Fact]
    public void ReclaimOnlyWhenTheLeaseNamesAnIdThisAppHeld()
    {
        ScreenViewer prior = Viewer("prior"), minted = Viewer("minted"), own = Viewer("own"), stranger = Viewer("stranger");
        Assert.True(ScreenHolds.ShouldReclaim(prior, minted, Human(prior), null));
        Assert.True(ScreenHolds.ShouldReclaim(null, minted, Human(own), own));
        Assert.False(ScreenHolds.ShouldReclaim(prior, minted, Human(stranger), own));
        Assert.False(ScreenHolds.ShouldReclaim(prior, minted, Human(minted), own));        // already ours
        Assert.False(ScreenHolds.ShouldReclaim(prior, minted, new ScreenLease(ScreenHolder.Agent, null, 4), own));
        Assert.False(ScreenHolds.ShouldReclaim(prior, minted, new ScreenLease(ScreenHolder.Human, null, 4), own));
        Assert.False(ScreenHolds.ShouldReclaim(prior, minted, null, own));
        Assert.False(ScreenHolds.ShouldReclaim(null, minted, Human(prior), null));
    }

    [Fact]
    public void HeldBeforeNeedsTheLeaseToStillNameTheSavedHold()
    {
        var old = Viewer("old");
        var saved = new SavedHold(old.Id, old.Hash, 0);
        Assert.Equal(saved, ScreenHolds.HeldBefore(saved, Human(old), Viewer("new")));
        Assert.Equal(saved, ScreenHolds.HeldBefore(saved, Human(old), null));
        Assert.Null(ScreenHolds.HeldBefore(saved, Human(old), old));                          // this attach holds it
        Assert.Null(ScreenHolds.HeldBefore(saved, Human(Viewer("other")), Viewer("new")));
        Assert.Null(ScreenHolds.HeldBefore(saved, new ScreenLease(ScreenHolder.Agent, null, 9), null));
        Assert.Null(ScreenHolds.HeldBefore(null, Human(old), null));
        Assert.Null(ScreenHolds.HeldBefore(saved, null, null));
    }

    [Fact]
    public void LeavingHandsBackHoweverControlIsHeld()
    {
        var mine = Viewer("mine");
        var saved = new SavedHold("old", ScreenWire.ViewerHash("old"), 0);
        Assert.Equal(new ScreenLeave.CloseHandsBack(), ScreenHolds.Leave(holding: true, streamOpen: true, mine, saved));
        Assert.Equal(new ScreenLeave.Release("mine"), ScreenHolds.Leave(holding: true, streamOpen: false, mine, saved));
        Assert.Equal(new ScreenLeave.Release("old"), ScreenHolds.Leave(holding: false, streamOpen: true, mine, saved));
        Assert.Equal(new ScreenLeave.Nothing(), ScreenHolds.Leave(holding: false, streamOpen: false, mine, null));
        Assert.Equal(new ScreenLeave.Nothing(), ScreenHolds.Leave(holding: true, streamOpen: false, null, null));
    }

    [Fact]
    public void AHoldIsSavedAndReadBackForADayThenForgotten()
    {
        var (holds, defaults, clock) = Make();
        var mine = Viewer("abc123");
        holds.Note(Human(mine), mine, "acct", "default");
        Assert.Equal(mine, holds.Own("acct", "default"));
        Assert.Equal(new SavedHold(mine.Id, mine.Hash, 1_800_000_000), holds.Saved("acct", "default"));
        Assert.True(holds.Saved("acct", "writer") == null && holds.Saved("other", "default") == null);
        // Stored as {"id","hash","at"}.
        var stored = JsonNode.Parse(defaults.Get("hq.screen.held.acct.default") ?? "null") as JsonObject;
        Assert.Equal(new[] { "at", "hash", "id" }, (stored?.Select(p => p.Key) ?? []).Order(StringComparer.Ordinal));
        clock.Date += TimeSpan.FromSeconds(23 * 3600 + 3540);
        Assert.NotNull(holds.Saved("acct", "default"));                       // 23 h 59 m
        clock.Date += TimeSpan.FromSeconds(120);
        Assert.Null(holds.Saved("acct", "default"));                          // 24 h 1 m
        Assert.Null(defaults.Get("hq.screen.held.acct.default"));
    }

    [Fact]
    public void ABadSavedHoldIsIgnoredAndCleared()
    {
        var (holds, defaults, _) = Make();
        const string key = "hq.screen.held.acct.default";
        foreach (var bad in new[] { "not json", "{}", """{"id":"","hash":"","at":1}""", """{"id":"abc","hash":"zzz","at":1800000000}""", """{"id":1,"hash":2,"at":"x"}""", "[1,2]" })
        {
            defaults.Set(key, bad);
            Assert.True(holds.Saved("acct", "default") == null, bad);
            Assert.Null(defaults.Get(key));
        }
        defaults.Set(key, "42");                                              // UserDefaults set(42): the number as text here
        Assert.Null(holds.Saved("acct", "default"));
        defaults.Set(key, "\u0001\u0002\u0003");                              // set(Data([1, 2, 3]))
        Assert.Null(holds.Saved("acct", "default"));
        Assert.Null(defaults.Get(key));
        // A hold dated in the future (a clock change) is not trusted either.
        const string id = "future";
        defaults.Set(key, $$"""{"id":"future","hash":"{{ScreenWire.ViewerHash(id)}}","at":1900000000}""");
        Assert.Null(holds.Saved("acct", "default"));
    }

    [Fact]
    public void TheSavedHoldEndsWhenTheLeaseIsSomeoneElses()
    {
        var (holds, _, _) = Make();
        var mine = Viewer("mine");
        holds.Note(Human(mine), mine, "a", "p");
        // A status with no viewer of ours yet (a relaunch): the saved hold stays while the lease names it.
        holds.Note(Human(mine, epoch: 4), null, "a", "p");
        Assert.NotNull(holds.Saved("a", "p"));
        // Another person took it.
        holds.Note(Human(Viewer("other"), epoch: 5), Viewer("new"), "a", "p");
        Assert.Null(holds.Saved("a", "p"));
        Assert.Equal(mine, holds.Own("a", "p"));                              // this run still knows what it held
        // The bot has it: nothing left to reclaim.
        holds.Note(Human(mine, epoch: 6), mine, "a", "p");
        holds.Note(new ScreenLease(ScreenHolder.Agent, null, 7), mine, "a", "p");
        Assert.True(holds.Saved("a", "p") == null && holds.Own("a", "p") == null);
        holds.Note(null, mine, "a", "p");
        Assert.Null(holds.Saved("a", "p"));
    }

    [Fact]
    public void TheNewestHoldReplacesTheOlder()
    {
        var (holds, _, _) = Make();
        ScreenViewer first = Viewer("first"), second = Viewer("second");
        holds.Note(Human(first), first, "a", "p");
        holds.Note(Human(second, epoch: 9), second, "a", "p");
        Assert.True(holds.Own("a", "p") == second && holds.Saved("a", "p")?.Id == "second");
        holds.Forget("a", "p");
        Assert.Null(holds.Saved("a", "p"));
    }

    [Fact]
    public void TheGatewaysKindAndTheRotateHintAreRemembered()
    {
        var (holds, defaults, _) = Make();
        Assert.Null(holds.RememberedKind("acct"));
        holds.RememberKind(ScreenKind.Unknown, "acct");
        Assert.Null(holds.RememberedKind("acct"));
        holds.RememberKind(ScreenKind.Screenshots, "acct");
        Assert.True(holds.RememberedKind("acct") == ScreenKind.Screenshots && holds.RememberedKind("other") == null);
        holds.RememberKind(ScreenKind.Live, "acct");
        Assert.Equal(ScreenKind.Live, holds.RememberedKind("acct"));
        defaults.Set("hq.screen.kind.acct", "nonsense");
        Assert.Null(holds.RememberedKind("acct"));
        Assert.False(holds.RotateHintSeen);
        holds.RotateHintSeen = true;
        Assert.True(holds.RotateHintSeen && defaults.Get("hq.screen.rotateHintSeen") == "true");
    }

    // Windows-only addition (no Swift twin): the keys are the Mac's, word for word, so a store moved between builds
    // reads the same.
    [Fact]
    public void TheKeysAreTheMacs()
    {
        Assert.Equal("acct|default", ScreenHolds.Key("acct", "default"));
        Assert.Equal("hq.screen.held.acct.default", ScreenHolds.HeldKey("acct", "default"));
        Assert.Equal("hq.screen.kind.acct", ScreenHolds.KindKey("acct"));
        Assert.Equal("hq.screen.rotateHintSeen", ScreenHolds.RotateHintKey);
        Assert.Equal(TimeSpan.FromHours(24), ScreenHolds.MaxAge);
    }
}
