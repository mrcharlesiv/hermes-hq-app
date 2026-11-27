// [WIN-SCREEN-WIRE-KEYS-MATH] Bot Screen's wire (Hermes.Core/Screen/ScreenWire.cs), ported case for case from the Mac's
// Tests/Screen/ScreenWireTests.swift at 93f984bb1: status and lease parsing, the exact params of the five calls, the
// viewer hash, the socket address, old names in gateway text (D27), tone, kind and the screen label. The Swift RPCError
// is Hermes.Core's GatewayException (Code "rpc" with RpcCode; "timeout"; "offline"), CancellationError is
// OperationCanceledException. Synthetic values only.

using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Screen;

namespace Hermes.Core.Tests.Screen;

public class ScreenWireTests
{
    internal static JsonNode? Value(string json) => JsonNode.Parse(json);

    private static GatewayException Rpc(long code, string message) => new("rpc", message, rpcCode: code);

    [Fact]
    public void GatewayTextNeverCarriesTheOldNames()
    {
        Assert.Equal("Allow Screen Recording for Hermes HQ Screen on the Mac", ScreenWire.Plain("Allow Screen Recording for Dispatch Screen on the Mac"));
        Assert.Equal("the hermes-hq-screen plugin is off", ScreenWire.Plain("  the dispatch-screen plugin is off \n"));
        Assert.Equal("Hermes HQ Screen is paused", ScreenWire.Plain("DISPATCH SCREEN is paused"));
        Assert.Equal("Open Hermes HQ to continue", ScreenWire.Plain("Open Dispatch to continue"));
        Assert.Equal("Nothing to change.", ScreenWire.Plain("Nothing to change."));
        Assert.DoesNotContain("dispatch", ScreenWire.Message(Rpc(5300, "Dispatch Screen is not running")).ToLowerInvariant());
    }

    [Fact]
    public void StatusParsesWithEveryFieldOptional()
    {
        var full = ScreenStatus.Parse(Value("""
        {"profile_key":"default","supported":true,"installed":true,"running":true,"missing":["Xvnc"],"display":"This Mac",
         "geometry":"1920x1080","install_command":"brew install x","blocker":null,"placement":"terminal:docker",
         "lease":{"holder":"human","viewer_hash":"abcdef012345","epoch":4}}
        """));
        Assert.NotNull(full);
        Assert.True(full.Supported && full.Installed && full.Running && full.IsMac && !full.IsBlocked);
        Assert.Equal(new ScreenLease(ScreenHolder.Human, "abcdef012345", 4), full.Lease);
        Assert.True(full.Missing.SequenceEqual(["Xvnc"]) && full.Placement == "terminal:docker");
        var empty = ScreenStatus.Parse(Value("{}"));
        Assert.NotNull(empty);
        Assert.True(!empty.Supported && !empty.Installed && !empty.Running && empty.Lease == null && empty.Display == null);
    }

    [Fact]
    public void WrongShapesAreNoStatusNeverACrash()
    {
        foreach (var bad in new[] { "null", "[]", "\"text\"", "7", "true" }) Assert.True(ScreenStatus.Parse(Value(bad)) == null, bad);
        Assert.Null(ScreenStatus.Parse(null));
        var odd = ScreenStatus.Parse(Value("{\"lease\":\"x\",\"geometry\":7,\"supported\":\"yes\",\"missing\":\"all\",\"blocker\":5}"));
        Assert.NotNull(odd);
        Assert.True(odd.Lease == null && odd.Geometry == null && !odd.Supported && odd.Missing.Count == 0 && odd.Blocker == null);
        Assert.Null(ScreenLease.Parse(Value("{\"holder\":\"nobody\"}")));
        Assert.Equal(0, ScreenLease.Parse(Value("{\"holder\":\"agent\",\"epoch\":-5}"))?.Epoch);
        var blank = ScreenLease.Parse(Value("{\"holder\":\"human\",\"viewer_hash\":\"\"}"));
        Assert.NotNull(blank);
        Assert.Null(blank.ViewerHash);
    }

    [Fact]
    public void BlockerIsShownInCurrentWordsAndMarksTheScreenBlocked()
    {
        var status = ScreenStatus.Parse(Value("{\"supported\":true,\"installed\":true,\"running\":false,\"blocker\":\"Allow Screen Recording for Dispatch Screen on the Mac\"}"));
        Assert.NotNull(status);
        Assert.True(status.IsBlocked);
        Assert.Equal("Allow Screen Recording for Hermes HQ Screen on the Mac", status.Blocker);
        var running = status with { Running = true };
        Assert.False(running.IsBlocked);
    }

    [Fact]
    public void AnOlderLeaseIsIgnored()
    {
        var held = new ScreenLease(ScreenHolder.Human, "a", 5);
        Assert.True(new ScreenLease(ScreenHolder.Agent, Epoch: 4).IsOlder(held));
        Assert.False(new ScreenLease(ScreenHolder.Agent, Epoch: 5).IsOlder(held));
        Assert.False(new ScreenLease(ScreenHolder.Agent, Epoch: 0).IsOlder(null));
    }

    [Fact]
    public void TheFiveCallsSendExactlyTheirKeys()
    {
        static string[] Keys(JsonObject value) => value.Select(p => p.Key).Order(StringComparer.Ordinal).ToArray();
        Assert.Equal(["profile"], Keys(ScreenWire.ProfileParams("ivy")));
        Assert.Equal(["profile"], Keys(ScreenWire.ObserveParams("ivy", null)));
        Assert.Equal(["profile"], Keys(ScreenWire.ObserveParams("ivy", "")));
        Assert.Equal(["profile", "viewer_id"], Keys(ScreenWire.ObserveParams("ivy", "v1")));
        Assert.Equal(["profile", "viewer_id"], Keys(ScreenWire.AcquireParams("ivy", "v1")));
        Assert.Equal(["profile", "viewer_id"], Keys(ScreenWire.ReleaseParams("ivy", "v1", force: false)));
        Assert.Equal(["force", "profile", "viewer_id"], Keys(ScreenWire.ReleaseParams("ivy", "v1", force: true)));
        var bare = ScreenWire.ReleaseParams("ivy", null, force: true);
        Assert.Equal(["force", "profile"], Keys(bare));
        Assert.True(bare["force"]!.GetValue<bool>());
        Assert.Equal("ivy", bare["profile"]!.GetValue<string>());
    }

    [Fact]
    public void OlderHermesWithoutTheCallsIsUnavailable()
    {
        Assert.True(ScreenWire.IsUnavailable(Rpc(-32601, "nope")));
        Assert.True(ScreenWire.IsUnavailable(Rpc(1, "Method not found: display.status")));
        Assert.True(ScreenWire.IsUnavailable(Rpc(1, "unknown method")));
        Assert.False(ScreenWire.IsUnavailable(Rpc(5300, "Bot Desktop is not running")));
        Assert.False(ScreenWire.IsUnavailable(new OperationCanceledException()));
    }

    [Fact]
    public void TheViewerHashIsTheFirstTwelveHexOfSHA256()
    {
        Assert.Equal("ba7816bf8f01", ScreenWire.ViewerHash("abc"));
        Assert.Equal("ba7816bf8f01", new ScreenViewer("abc").Hash);
        var mine = new ScreenViewer("abc");
        Assert.True(ScreenWire.Holds(new ScreenLease(ScreenHolder.Human, "ba7816bf8f01", 1), mine));
        Assert.False(ScreenWire.Holds(new ScreenLease(ScreenHolder.Human, "000000000000", 1), mine));
        Assert.False(ScreenWire.Holds(new ScreenLease(ScreenHolder.Agent, "ba7816bf8f01", 1), mine));
        Assert.True(!ScreenWire.Holds(null, mine) && !ScreenWire.Holds(new ScreenLease(ScreenHolder.Human, "ba7816bf8f01"), null));
    }

    [Fact]
    public void TheSocketAddressCarriesOnlyTheTicket()
    {
        var plain = ScreenWire.DisplaySocketUrl(new Uri("http://127.0.0.1:9940"), "/api/display/ws", "t-1");
        Assert.NotNull(plain);
        Assert.Equal("ws://127.0.0.1:9940/api/display/ws?display_ticket=t-1", plain.AbsoluteUri);
        var secure = ScreenWire.DisplaySocketUrl(new Uri("https://user:pw@gw.example.test/hermes/?x=1#frag"), "/api/display/ws", "a b");
        Assert.NotNull(secure);
        Assert.True(secure.Scheme == "wss" && secure.AbsolutePath == "/hermes/api/display/ws" && secure.UserInfo == "" && secure.Fragment == "");
        // The query is the one item, display_ticket = "a b".
        var query = secure.Query.TrimStart('?').Split('&');
        Assert.Single(query);
        var pair = query[0].Split('=', 2);
        Assert.Equal("display_ticket", pair[0]);
        Assert.Equal("a b", Uri.UnescapeDataString(pair[1]));
    }

    [Fact]
    public void APathOtherThanTheDisplayRouteIsNeverDialled()
    {
        var @base = new Uri("http://127.0.0.1:9940");
        foreach (var path in new[] { "/api/ws", "//evil.example/api/display/ws", "/api/display/ws/", "api/display/ws", "", "/api/display/ws?x=1", "https://evil.example/api/display/ws" })
            Assert.True(ScreenWire.DisplaySocketUrl(@base, path, "t") == null, path);
        Assert.Null(ScreenWire.DisplaySocketUrl(@base, "/api/display/ws", ""));
        Assert.Null(ScreenWire.DisplaySocketUrl(new Uri("ftp://x.test"), "/api/display/ws", "t"));
    }

    [Fact]
    public void ObserveNeedsATicketAPathAndAViewerId()
    {
        var ok = ScreenObserved.Parse(Value("{\"supported\":true,\"installed\":true,\"running\":true,\"ticket\":\"t\",\"path\":\"/api/display/ws\",\"viewer_id\":\"v\"}"));
        Assert.True(ok?.Viewer.Id == "v" && ok?.Ticket == "t" && ok?.Status.Running == true);
        Assert.Null(ScreenObserved.Parse(Value("{\"path\":\"/api/display/ws\",\"viewer_id\":\"v\"}")));
        Assert.Null(ScreenObserved.Parse(Value("{\"ticket\":\"t\",\"viewer_id\":\"v\"}")));
        Assert.Null(ScreenObserved.Parse(Value("{\"ticket\":\"t\",\"path\":\"/api/display/ws\"}")));
        Assert.Null(ScreenObserved.Parse(Value("{\"ticket\":7,\"path\":\"/api/display/ws\",\"viewer_id\":\"v\"}")));
    }

    [Fact]
    public void AFailedCallReadsInPlainWordsWithOnePeriod()
    {
        Assert.Equal("The gateway refused the request.", ScreenWire.Message(Rpc(5300, "")));
        Assert.Equal("The screen is busy.", ScreenWire.Sentence("The screen is busy."));
        Assert.Equal("The screen is busy.", ScreenWire.Sentence("The screen is busy"));
        Assert.Equal("Wait.", ScreenWire.Sentence(" Wait... "));
    }

    // Windows-only addition (no Swift twin): the other failures Message words, as the Swift `message` does for
    // RPCError.isTimeout / isConnectionLost / isNotConnected and CancellationError.
    [Fact]
    public void TimeoutsDropsAndCancelsReadInTheMacsWords()
    {
        Assert.Equal("The gateway took too long to answer.", ScreenWire.Message(new GatewayException("timeout", "x")));
        Assert.Equal("The connection to the gateway was lost.", ScreenWire.Message(new GatewayException("offline", "x")));
        Assert.Equal("The request was cancelled.", ScreenWire.Message(new OperationCanceledException()));
        Assert.Equal("Hermes HQ broke", ScreenWire.Message(new InvalidOperationException(" Dispatch broke ")));
    }
}

public class ScreenToneTests
{
    private static ScreenStatus Status(string json) => ScreenStatus.Parse(ScreenWireTests.Value(json))!;

    [Fact]
    public void ToneFollowsTheStatus()
    {
        var me = new ScreenViewer("abc");
        Assert.Equal(ScreenTone.Unavailable, ScreenWire.Tone(true, null, null));
        Assert.Equal(ScreenTone.Unknown, ScreenWire.Tone(false, null, null));
        Assert.Equal(ScreenTone.Unsupported, ScreenWire.Tone(false, Status("{\"supported\":false}"), null));
        Assert.Equal(ScreenTone.Missing, ScreenWire.Tone(false, Status("{\"supported\":true,\"installed\":false}"), null));
        Assert.Equal(ScreenTone.Off, ScreenWire.Tone(false, Status("{\"supported\":true,\"installed\":true,\"running\":false}"), null));
        const string live = "{\"supported\":true,\"installed\":true,\"running\":true";
        Assert.Equal(ScreenTone.Live, ScreenWire.Tone(false, Status(live + "}"), me));
        Assert.Equal(ScreenTone.Live, ScreenWire.Tone(false, Status(live + ",\"lease\":{\"holder\":\"agent\",\"epoch\":2}}"), me));
        Assert.Equal(ScreenTone.Human, ScreenWire.Tone(false, Status(live + ",\"lease\":{\"holder\":\"human\",\"viewer_hash\":\"ba7816bf8f01\",\"epoch\":2}}"), me));
        Assert.Equal(ScreenTone.Other, ScreenWire.Tone(false, Status(live + ",\"lease\":{\"holder\":\"human\",\"viewer_hash\":\"ffffffffffff\",\"epoch\":2}}"), me));
        Assert.Equal(ScreenTone.Other, ScreenWire.Tone(false, Status(live + ",\"lease\":{\"holder\":\"human\",\"viewer_hash\":\"ba7816bf8f01\",\"epoch\":2}}"), null));
    }

    // bot-screen-labels.test.ts: "says the neutral View screen until a gateway's answer is known, then what that gateway
    // gave, for every bot on it".
    [Fact]
    public void TheMenuSaysWhatTheGatewayGaveOnceKnown()
    {
        var remembered = new Dictionary<string, ScreenKind>();
        string Label(ScreenTone tone, string gateway)
        {
            var answer = ScreenWire.Kind(tone, remembered.TryGetValue(gateway, out var k) ? k : null);
            if (answer.Remember is { } keep) remembered[gateway] = keep;
            return answer.Kind.MenuTitle();
        }
        Assert.Equal("View Screen", Label(ScreenTone.Unknown, "mac-1"));
        Assert.Equal("Latest Screenshots", Label(ScreenTone.Unsupported, "mac-1"));
        Assert.Equal("Latest Screenshots", Label(ScreenTone.Unknown, "mac-1"));   // another bot on the same gateway, before its own answer
        Assert.Equal("View Screen", Label(ScreenTone.Unknown, "linux-1"));
        foreach (var tone in new[] { ScreenTone.Live, ScreenTone.Off, ScreenTone.Missing, ScreenTone.Human, ScreenTone.Other })
            Assert.Equal("Watch Screen", Label(tone, "linux-1"));
        Assert.Equal("Watch Screen", Label(ScreenTone.Unknown, "linux-1"));
        Assert.Equal("Latest Screenshots", Label(ScreenTone.Unavailable, "old-hermes"));
    }

    [Fact]
    public void KindsHaveTheirSymbols()
    {
        Assert.Equal("photo.on.rectangle", ScreenKind.Screenshots.Symbol());
        Assert.True(ScreenKind.Live.Symbol() == "display" && ScreenKind.Unknown.Symbol() == "display");
    }

    [Fact]
    public void TheScreenLabelLeavesOutAnXDisplayNumber()
    {
        Assert.Equal("", ScreenWire.ScreenLabel(null));
        Assert.Equal("This Mac · 1920×1080", ScreenWire.ScreenLabel(Status("{\"display\":\"This Mac\",\"geometry\":\"1920x1080\"}")));
        Assert.Equal("1280×800", ScreenWire.ScreenLabel(Status("{\"display\":\":7\",\"geometry\":\"1280x800\"}")));
        Assert.Equal("", ScreenWire.ScreenLabel(Status("{\"display\":\":7.0\"}")));
        Assert.Equal("This Mac", ScreenWire.ScreenLabel(Status("{\"display\":\"This Mac\"}")));
        Assert.Equal("This Mac · wide", ScreenWire.ScreenLabel(Status("{\"display\":\"This Mac\",\"geometry\":\"wide\"}")));
        Assert.True(ScreenWire.Size("1920x1080")?.Width == 1920 && ScreenWire.Size("1920x1080")?.Height == 1080);
        Assert.True(ScreenWire.Size("0x10") == null && ScreenWire.Size("wide") == null && ScreenWire.Size(null) == null);
    }
}
