// [WIN-SCREEN-SERVICE] The account's Bot Screen service (docs/spec/3x-screen.md §3.1, §5.1, §5.4, §5.13): the cases of
// the Mac's ScreenServiceTests suite (Tests/Screen/ScreenSessionTests.swift at 93f984bb1) that are the service's own.
// Its six session cases are in ScreenSessionTests (WIN-SCREEN-SESSION), now on this real service too. Same collection
// as the session tests: the Mac runs both suites .serialized on its main actor.

using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Screen;
using static Hermes.Core.Tests.Screen.ScreenWaits;
using P = Hermes.Core.Screen.ScreenSession.Phase;

namespace Hermes.Core.Tests.Screen;

[Collection("ScreenSession")]
public sealed class ScreenServiceTests
{
    private static JsonObject J(string text) => (JsonObject)JsonNode.Parse(text)!;

    [Fact]
    public async Task TheMenuLabelFollowsWhatIsKnownAndIsRememberedForTheGateway()
    {
        using var rig = new SessionRig();
        Assert.True(rig.Main.Read(() => rig.Service.Kind("default") == ScreenKind.Unknown && rig.Service.Kind("writer") == ScreenKind.Unknown));
        Assert.Empty(rig.Display.Methods);                                                  // asking for a label reads nothing
        Assert.True(await rig.OpenLive());
        Assert.Equal(ScreenKind.Live, rig.Main.Read(() => rig.Service.Kind("default")));
        Assert.Equal(ScreenKind.Live, rig.Main.Read(() => rig.Service.Kind("writer")));     // never opened: the gateway's kind
        rig.Do(s => s.Leave());
        Assert.Equal(ScreenKind.Live, rig.Main.Read(() => rig.Service.Kind("default")));
        Assert.Equal(ScreenKind.Live, rig.Holds.RememberedKind(rig.Account));
        // The gateway loses its screen: the next open learns it and the label follows, for a relaunch too.
        rig.Display.Set(s => s.Supported = false);
        rig.Reopen();
        rig.Do(s => s.Open());
        Assert.True(await ScreenWait(() => rig.Phase == new P.FallbackTo(ScreenSession.Fallback.Unsupported)));
        Assert.True(rig.Main.Read(() => rig.Service.Kind("default") == ScreenKind.Screenshots && rig.Service.Kind("writer") == ScreenKind.Screenshots));
        var relaunched = new ScreenHolds(rig.Defaults);
        Assert.Equal(ScreenKind.Screenshots, relaunched.RememberedKind(rig.Account));
        rig.Do(s => s.Leave());
    }

    /// As Hermes sends them: `profile_key` is the profile's home path, a status also says the name, a lease event
    /// says the path only (review finding 1: the cache was filed under the path and the menu never saw it).
    [Fact]
    public async Task EventsFeedTheLabelsOfBotsThatWereNeverOpened()
    {
        using var rig = new SessionRig();
        const string key = "/srv/hermes/homes/w-1";                                     // nothing in the path names the bot
        var changes = 0;
        rig.Main.Run(() => rig.Service.KnownChanged += () => changes++);
        rig.Display.Emit("display.status", J($$$"""
            {"profile":"writer","profile_key":"{{{key}}}","supported":true,"installed":true,"running":true,
             "lease":{"holder":"human","viewer_hash":"abc","epoch":3}}
            """));
        Assert.True(await ScreenWait(() => rig.Main.Read(() => rig.Service.Tone("writer")) == ScreenTone.Other));
        rig.Display.Emit("display.lease", J($$$"""{"profile_key":"{{{key}}}","lease":{"holder":"agent","viewer_hash":null,"epoch":4}}"""));
        Assert.True(await ScreenWait(() => rig.Main.Read(() => rig.Service.Tone("writer")) == ScreenTone.Live));
        rig.Display.Emit("display.lease", J($$$"""{"profile_key":"{{{key}}}","lease":{"holder":"human","viewer_hash":"abc","epoch":2}}"""));
        await Task.Delay(80);
        Assert.Equal(ScreenTone.Live, rig.Main.Read(() => rig.Service.Tone("writer")));      // an older lease changes nothing
        Assert.Equal(ScreenKind.Live, rig.Main.Read(() => rig.Service.Kind("writer")));
        Assert.Equal(ScreenTone.Unknown, rig.Main.Read(() => rig.Service.Tone("/srv/hermes/homes/w-1")));   // nothing is filed under a path
        // Bot Info's Screen row reads again on each change (the Swift `knownChanged` notification).
        Assert.True(rig.Main.Read(() => changes) >= 2);
    }

    [Fact]
    public async Task ALeaseEventForAHomeNobodyNamedChangesNothing()
    {
        using var rig = new SessionRig();
        rig.Display.Emit("display.lease", J("""{"profile_key":"/srv/hermes/homes/x-9","lease":{"holder":"human","viewer_hash":"abc","epoch":9}}"""));
        await Task.Delay(80);
        Assert.Equal(ScreenTone.Unknown, rig.Main.Read(() => rig.Service.Tone("/srv/hermes/homes/x-9")));
        Assert.Null(rig.Main.Read(() => rig.Service.ProfileName(J("""{"profile_key":"/srv/hermes/homes/x-9"}"""))));
        // Hermes' own layout names the bot; "custom" is not a name; an old gateway's bare name still works.
        Assert.Equal("ivy", rig.Main.Read(() => rig.Service.ProfileName(J("""{"profile_key":"/Users/x/.hermes/profiles/ivy"}"""))));
        Assert.Null(rig.Main.Read(() => rig.Service.ProfileName(J("""{"profile":"custom","profile_key":"/opt/elsewhere"}"""))));
        Assert.Equal("writer", rig.Main.Read(() => rig.Service.ProfileName(J("""{"profile_key":"writer"}"""))));
    }

    /// An open Screen teaches the pairing: the bot's lease events move its label after the Screen is closed.
    [Fact]
    public async Task AnOpenedScreenPairsItsHomeWithItsBot()
    {
        using var rig = new SessionRig();
        Assert.True(await rig.OpenLive());
        rig.Do(s => s.Leave());
        Assert.Equal(ScreenTone.Live, rig.Main.Read(() => rig.Service.Tone("default")));
        rig.Display.OtherTakes();
        Assert.True(await ScreenWait(() => rig.Main.Read(() => rig.Service.Tone("default")) == ScreenTone.Other));
        rig.Display.AgentTakes();
        Assert.True(await ScreenWait(() => rig.Main.Read(() => rig.Service.Tone("default")) == ScreenTone.Live));
    }

    [Fact]
    public async Task CheckSetupReadsHealthAndStatusTogether()
    {
        using var rig = new SessionRig();
        rig.Display.OnRest(() => """{"installed":true,"ok":true,"platform":"darwin","drift":[],"enabled":true,"control":false,"helper":{"ok":true,"tcc":{"screen":true,"events":true}}}""");
        Assert.Equal("Viewing is ready. Finish setup with Hermes to enable pointer, clicks, and typing.", await rig.CheckSetup("default"));
        Assert.True(rig.Display.Methods.SequenceEqual(["display.status"]) && rig.Display.RestLog.Count == 1);
        // No plugin route at all is an answer, not a failure.
        rig.Display.OnRest(() => null);
        Assert.Equal("The Mac screen plugin is not loaded in this gateway yet.", await rig.CheckSetup("default"));
        // A gateway that cannot be reached is a failure (URLError(.timedOut)).
        rig.Display.OnRest(() => throw new IOException("The request timed out."));
        await Assert.ThrowsAsync<IOException>(() => rig.CheckSetup("default"));
        // An older Hermes without display.* still gets a plain line.
        rig.Display.OnRest(() => """{"installed":true,"ok":true,"platform":"darwin","drift":[],"enabled":true}""");
        rig.Display.Set(s => s.Fail["display.status"] = FakeDisplay.Rpc(-32601, "Method not found"));
        Assert.Equal("This bot does not have access to the Mac’s screen.", await rig.CheckSetup("default"));
    }

    // Beyond the Swift cases: the C# wiring the Swift gets from its client (events(matching:), connectionStates()).

    /// Only `display.status` / `display.lease` reach the service; a new connection (not the first state) reaches every
    /// open Screen; after sign-out nothing is read.
    [Fact]
    public async Task OnlyDisplayEventsAndARealReconnectReachTheService()
    {
        using var rig = new SessionRig();
        Assert.Equal(["display.lease", "display.status"], rig.Display.SubscribedTypes.Order(StringComparer.Ordinal));
        Assert.Equal(1, rig.Display.StateSubscribers);
        rig.Display.Emit("display.status.other", J("""{"profile":"writer","supported":true,"installed":true,"running":true}"""));
        await Task.Delay(80);
        Assert.Equal(ScreenTone.Unknown, rig.Main.Read(() => rig.Service.Tone("writer")));
        rig.Main.Run(rig.Service.Shutdown);
        Assert.Empty(rig.Display.SubscribedTypes);
        Assert.Equal(0, rig.Display.StateSubscribers);
    }
}
