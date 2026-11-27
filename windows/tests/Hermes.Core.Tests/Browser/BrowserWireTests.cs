// Watch Browser wire, address, keyboard, health, add-on, card, layout & preview tab unit tests.

using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Browser;
using Hermes.Core.Composer;
using Hermes.Core.Gateways;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests.Browser;

public sealed class BrowserWireTests
{
    private const string IdA = "0123456789abcdef01234567";
    private const string IdB = "abcdef0123456789abcdef01";

    private sealed class MemoryStore : IKeyValueStore
    {
        private readonly Dictionary<string, string> _map = [];
        public string? Get(string key) => _map.TryGetValue(key, out var v) ? v : null;
        public void Set(string key, string? value)
        {
            if (value == null) _map.Remove(key);
            else _map[key] = value;
        }
    }

    [Fact]
    public void BrowserIdAndWatchPathValidation()
    {
        Assert.True(BrowserWire.IsBrowserId(IdA));
        Assert.False(BrowserWire.IsBrowserId("short"));
        Assert.False(BrowserWire.IsBrowserId("0123456789ABCDEF01234567")); // uppercase rejected
        Assert.False(BrowserWire.IsBrowserId("0123456789abcdef0123456g")); // non-hex
        Assert.False(BrowserWire.IsBrowserId(null));

        Assert.Equal("/api/plugins/hermes-hq-browser/sessions/" + IdA + "/watch", BrowserWire.WatchPath(IdA));
        Assert.Equal("/api/plugins/dispatch-browser/sessions/" + IdA + "/watch", BrowserWire.WatchPath(IdA, BrowserWire.LegacyPlugin));
        Assert.Null(BrowserWire.WatchPath("../bad"));
    }

    [Fact]
    public void SocketUrlBuildsSecureAndPlainUrlsWithPrefixAndTicketLast()
    {
        var httpsBase = new Uri("https://gateway.example.com/sub/");
        var url = BrowserWire.SocketUrl(
            httpsBase,
            "/api/plugins/hermes-hq-browser/sessions/" + IdA + "/watch",
            [new("profile", "ivy"), new("ticket", "spoofed"), new("token", "nope")],
            "fresh-ticket");
        Assert.NotNull(url);
        Assert.Equal("wss", url!.Scheme);
        Assert.Equal("/sub/api/plugins/hermes-hq-browser/sessions/" + IdA + "/watch", url.AbsolutePath);
        Assert.Equal("?profile=ivy&ticket=fresh-ticket", url.Query);

        var httpBase = new Uri("http://127.0.0.1:8080");
        var plain = BrowserWire.SocketUrl(httpBase, "/api/plugins/dispatch-browser/activity", [], "t1");
        Assert.NotNull(plain);
        Assert.Equal("ws://127.0.0.1:8080/api/plugins/dispatch-browser/activity?ticket=t1", plain!.AbsoluteUri);

        Assert.Null(BrowserWire.SocketUrl(httpsBase, "/api/other/route", [], "t1"));
        Assert.Null(BrowserWire.SocketUrl(httpsBase, "/api/plugins/hermes-hq-browser/../secret", [], "t1"));
        Assert.Null(BrowserWire.SocketUrl(new Uri("ftp://gateway.example.com"), "/api/plugins/hermes-hq-browser/activity", [], "t1"));
    }

    [Fact]
    public void ViewerIdIsPersistedAndStableAndViewSizeIsBounded()
    {
        var store = new MemoryStore();
        var first = BrowserWire.ViewerId(store);
        Assert.Equal(32, first.Length);
        Assert.Matches("^[0-9a-f]{32}$", first);
        Assert.Equal(first, BrowserWire.ViewerId(store));

        Assert.Equal((64, 2048, 3.0), BrowserWire.ViewSize(10, 9999, 5.0));
        Assert.Equal((64, 64, 1.0), BrowserWire.ViewSize(double.NaN, double.PositiveInfinity, double.NaN));
        Assert.Equal((800, 600, 1.5), BrowserWire.ViewSize(799.6, 600.2, 1.5));

        Assert.True(BrowserWire.IsCloudHost(new Uri("https://ivy.agents.nousresearch.com")));
        Assert.False(BrowserWire.IsCloudHost(new Uri("https://gateway.example.com")));
    }

    [Fact]
    public void RowParsingActiveFallbackAndScopeMatching()
    {
        var now = new DateTimeOffset(2026, 11, 20, 12, 0, 0, TimeSpan.Zero);
        var recentTs = now.AddSeconds(-30).ToUnixTimeMilliseconds() / 1000.0;
        var staleTs = now.AddSeconds(-180).ToUnixTimeMilliseconds() / 1000.0;

        var listJson = JsonNode.Parse($$"""
            {
              "schema": "dispatch-browser.list.v3",
              "browsers": [
                { "id": "{{IdA}}", "profile": "ivy", "session_id": "chat-1", "session_ids": ["chat-0", "chat-1"], "url": "https://shop.example.com/item", "busy": 0, "control": "bot", "agent_at": {{recentTs}} },
                { "id": "{{IdB}}", "profile": "ivy", "session_id": "chat-2", "url": "https://docs.example.com", "busy": 0, "control": "person", "ask": "  Sign in please  ", "agent_at": {{staleTs}} },
                { "id": "bad-id", "profile": "wren" }
              ]
            }
            """)!;
        var rows = BrowserRow.ParseList(listJson, now);
        Assert.NotNull(rows);
        Assert.Equal(2, rows!.Count);
        Assert.True(rows[0].Active);
        Assert.True(rows[0].InUse);
        Assert.Equal("chat-1", rows[0].Driver);

        Assert.False(rows[1].Active);
        Assert.True(rows[1].InUse); // Control == Person and Ask != null
        Assert.Equal("Sign in please", rows[1].Ask);

        var botScope = new BrowserScope("ivy", "Ivy", ownChats: ["chat-1"]);
        Assert.Equal(IdA, botScope.Row(rows)?.Id); // newest agent_at
        Assert.Equal(IdA, botScope.DrivenRow(rows)?.Id);

        var chatOnlyScope = new BrowserScope("ivy", "Ivy", sessionIds: ["chat-2"], chatOnly: true);
        Assert.Equal(IdB, chatOnlyScope.Row(rows)?.Id);
        Assert.Equal(IdB, chatOnlyScope.DrivenRow(rows)?.Id);

        var emptyChatOnly = new BrowserScope("ivy", "Ivy", chatOnly: true);
        Assert.Null(emptyChatOnly.Row(rows));
        Assert.Null(emptyChatOnly.DrivenRow(rows));
    }

    [Fact]
    public void BrowserCardRulesWordsAndStatusLines()
    {
        var active = new BrowserRow(IdA, "ivy", sessionId: "c1", url: "https://www.shop.example.com/cart", active: true);
        var asking = active with { Ask = "Solve the check", Control = BrowserControl.Bot };
        var mine = active with { Control = BrowserControl.Person };
        var waiting = active with { Control = BrowserControl.Waiting };
        var idle = active with { Active = false };

        Assert.Equal("Browsing shop.example.com", BrowserCard.Words(active, "Ivy"));
        Assert.Equal("Ivy needs you in its browser", BrowserCard.Words(asking, "Ivy"));
        Assert.Equal("You’re using Ivy’s browser", BrowserCard.Words(mine, "Ivy"));
        Assert.Equal("Handing you the browser…", BrowserCard.Words(waiting, "Ivy"));
        Assert.Equal("Using its browser", BrowserCard.Words(active with { Url = "about:blank" }, "Ivy"));

        // Card keeps showing during a running turn even after the browser becomes idle
        var kept = BrowserCard.Row(idle, active, turnRunning: true);
        Assert.NotNull(kept);
        Assert.True(kept!.Active);
        Assert.Null(BrowserCard.Row(idle, active, turnRunning: false));

        // Bots row status line
        Assert.Equal("Browsing shop.example.com", BrowserCard.StatusLine(active));
        Assert.Equal("Needs you in its browser", BrowserCard.StatusLine(asking));
        Assert.Equal("You’re using its browser", BrowserCard.StatusLine(mine));
        Assert.Equal("Handing you its browser…", BrowserCard.StatusLine(waiting));
        Assert.Null(BrowserCard.StatusLine(idle));

        // BotRow picks asking browser regardless of chat, else own chat's browser
        var otherChatAsk = asking with { SessionId = "other-chat" };
        Assert.Equal(otherChatAsk, BrowserCard.BotRow([otherChatAsk], "ivy", new HashSet<string> { "own-chat" }));
        var otherChatNormal = active with { SessionId = "other-chat" };
        Assert.Null(BrowserCard.BotRow([otherChatNormal], "ivy", new HashSet<string> { "own-chat" }));
        Assert.Equal(active, BrowserCard.BotRow([active], "ivy", new HashSet<string> { "c1" }));
    }

    [Fact]
    public void ServerMessagesParseAllTypesAndDialogs()
    {
        Assert.Equal(BrowserServerMessage.Ping.Instance, BrowserServerMessage.Parse("""{"type":"ping"}"""));
        Assert.Equal(new BrowserServerMessage.Ended("closed"), BrowserServerMessage.Parse("""{"type":"ended"}"""));
        Assert.Equal(new BrowserServerMessage.Ended("gone"), BrowserServerMessage.Parse("""{"type":"ended","reason":"gone"}"""));
        Assert.Equal(new BrowserServerMessage.Error("unresponsive"), BrowserServerMessage.Parse("""{"type":"error","message":"unresponsive"}"""));
        Assert.Equal(new BrowserServerMessage.Copied("hello world"), BrowserServerMessage.Parse("""{"type":"copied","text":"hello world"}"""));

        var stateJson = """
            {
              "type": "state",
              "tabs": [{"id": "t1", "title": "Example", "url": "https://example.com"}],
              "tab": "t1",
              "follow": false,
              "control": {"state": "person", "mine": true, "epoch": 7},
              "ask": "Please sign in",
              "field": {"under": "email", "focus": "password"},
              "dialog": {
                "id": 42,
                "kind": "accounts",
                "site": "auth.example.com",
                "message": "Choose account",
                "accounts": [{"name": "Ivy", "email": "ivy@example.com"}]
              }
            }
            """;
        var parsedState = Assert.IsType<BrowserServerMessage.State>(BrowserServerMessage.Parse(stateJson));
        Assert.Single(parsedState.View.Tabs);
        Assert.Equal("t1", parsedState.View.Tab);
        Assert.False(parsedState.View.Follow);
        Assert.Equal(new BrowserControlState(BrowserControl.Person, true, 7), parsedState.View.Control);
        Assert.Equal("Please sign in", parsedState.View.Ask);
        Assert.Equal(new BrowserPageFields(BrowserFieldKind.Email, BrowserFieldKind.Password), parsedState.View.Field);
        Assert.NotNull(parsedState.View.Dialog);
        Assert.Equal(BrowserPageDialogKind.Accounts, parsedState.View.Dialog!.Kind);
        Assert.Single(parsedState.View.Dialog.Accounts);
        Assert.Equal("ivy@example.com", parsedState.View.Dialog.Accounts[0].Email);

        // Prompt dialog preserves default text; accounts dialog with 0 accounts is dropped
        var promptJson = """
            {"type":"state","tabs":[],"control":{"state":"person","mine":true,"epoch":1},
             "dialog":{"id":5,"kind":"prompt","site":"example.com","message":"Code?","default":"1234"}}
            """;
        var promptState = Assert.IsType<BrowserServerMessage.State>(BrowserServerMessage.Parse(promptJson));
        Assert.Equal("1234", promptState.View.Dialog?.DefaultText);

        var emptyAccountsJson = """
            {"type":"state","tabs":[],"control":{"state":"person","mine":true,"epoch":1},
             "dialog":{"id":6,"kind":"accounts","accounts":[]}}
            """;
        var emptyAccState = Assert.IsType<BrowserServerMessage.State>(BrowserServerMessage.Parse(emptyAccountsJson));
        Assert.Null(emptyAccState.View.Dialog);

        // Frame parsing: valid JPEG data URL vs rejected non-JPEG or bad base64
        var validJpegB64 = Convert.ToBase64String([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]);
        var frameJson = $$"""{"type":"frame","seq":3,"tab":"t1","epoch":2,"width":1280,"height":800,"image":"data:image/jpeg;base64,{{validJpegB64}}"}""";
        var frameMsg = Assert.IsType<BrowserServerMessage.Frame>(BrowserServerMessage.Parse(frameJson));
        Assert.Equal(3, frameMsg.Data.Seq);
        Assert.Equal(1280, frameMsg.Data.Width);
        Assert.Equal(6, frameMsg.Data.Jpeg.Length);

        Assert.Null(BrowserServerMessage.Parse("""{"type":"frame","seq":1,"width":100,"height":100,"image":"data:image/png;base64,iVBORw=="}"""));
        Assert.Null(BrowserServerMessage.Parse("""{"type":"frame","seq":0,"width":100,"height":100,"image":"data:image/jpeg;base64,/9j/AA=="}"""));
        Assert.Null(BrowserServerMessage.Parse("not json"));
    }

    [Fact]
    public void ClientMessagesSerializeSortedKeysEpochsAndRoundedCoords()
    {
        Assert.Equal("""{"type":"hello","viewer":"abc"}""", new BrowserClientMessage.Hello("abc").ToJson());
        Assert.Equal("""{"height":600,"scale":2,"type":"view","width":800}""", new BrowserClientMessage.View(800, 600, 2).ToJson());
        Assert.Equal("""{"seq":9,"type":"ack"}""", new BrowserClientMessage.Ack(9).ToJson());
        Assert.Equal("""{"type":"pong"}""", BrowserClientMessage.Pong.Instance.ToJson());
        Assert.Equal("""{"type":"take"}""", BrowserClientMessage.Take.Instance.ToJson());
        Assert.Equal("""{"type":"give"}""", BrowserClientMessage.Give.Instance.ToJson());
        Assert.Equal("""{"type":"follow"}""", BrowserClientMessage.Follow.Instance.ToJson());
        Assert.Equal("""{"id":"tab-2","type":"tab"}""", new BrowserClientMessage.Tab("tab-2").ToJson());

        // Move clamps and rounds to 4 decimals and injects epoch
        var moveJson = new BrowserClientMessage.Input(new BrowserInput.Move(0.123456, 1.5)).ToJson(epoch: 4);
        using var moveDoc = JsonDocument.Parse(moveJson);
        Assert.Equal("move", moveDoc.RootElement.GetProperty("type").GetString());
        Assert.Equal(0.1235, moveDoc.RootElement.GetProperty("x").GetDouble());
        Assert.Equal(1.0, moveDoc.RootElement.GetProperty("y").GetDouble());
        Assert.Equal(4, moveDoc.RootElement.GetProperty("epoch").GetInt32());

        // Answer includes optional fields only when supplied
        var answerJson = new BrowserClientMessage.Input(new BrowserInput.Answer(7, true, Text: "ok", Account: 2)).ToJson(epoch: 3);
        Assert.Equal("""{"accept":true,"account":2,"epoch":3,"id":7,"text":"ok","type":"answer"}""", answerJson);

        var simpleAnswer = new BrowserClientMessage.Input(new BrowserInput.Answer(7, false)).ToJson();
        Assert.Equal("""{"accept":false,"id":7,"type":"answer"}""", simpleAnswer);
    }

    [Fact]
    public void KeyboardSlotsAndGraphemeSafePasteChunks()
    {
        Assert.Equal((BrowserKeyboardSlot.Password, BrowserKeyboardKind.Text), BrowserKeyboard.Slot(BrowserFieldKind.Password));
        Assert.Equal((BrowserKeyboardSlot.Username, BrowserKeyboardKind.Email), BrowserKeyboard.Slot(BrowserFieldKind.Email));
        Assert.Equal((BrowserKeyboardSlot.Code, BrowserKeyboardKind.Text), BrowserKeyboard.Slot(BrowserFieldKind.Code));
        Assert.Equal((BrowserKeyboardSlot.Text, BrowserKeyboardKind.Decimal), BrowserKeyboard.Slot(BrowserFieldKind.Number));
        Assert.Equal((BrowserKeyboardSlot.Text, BrowserKeyboardKind.Text), BrowserKeyboard.Slot(null));

        // Multi-scalar family emoji must never be split across chunk boundaries
        var emoji = "\U0001F468\u200D\U0001F469\u200D\U0001F467";
        var chunks = BrowserKeyboard.PasteChunks("ab" + emoji + "cd\r\nef", size: 4);
        Assert.Equal(["ab", emoji, "cd\ne", "f"], chunks);
    }

    [Fact]
    public void AddressParsingUrlResolutionAndBlankCheck()
    {
        Assert.Equal(new BrowserAddress("shop.example.com", true), BrowserAddress.Parse("https://www.shop.example.com/deals"));
        Assert.Equal(new BrowserAddress("shop.example.com", false), BrowserAddress.Parse("http://shop.example.com"));
        Assert.Equal(new BrowserAddress("New Tab", false), BrowserAddress.Parse("about:blank"));

        Assert.Equal("https://example.com/path", BrowserAddress.UrlFrom("https://example.com/path"));
        Assert.Equal("https://example.com/docs", BrowserAddress.UrlFrom("example.com/docs"));
        Assert.Equal("https://duckduckgo.com/?q=hermes%20watch%20browser", BrowserAddress.UrlFrom("hermes watch browser"));
        Assert.Null(BrowserAddress.UrlFrom("   "));

        Assert.True(BrowserAddress.IsBlank(""));
        Assert.True(BrowserAddress.IsBlank("about:blank"));
        Assert.True(BrowserAddress.IsBlank("chrome://newtab/"));
        Assert.False(BrowserAddress.IsBlank("https://example.com"));
    }

    [Fact]
    public void HealthSetupDriftAddOnVersionsAndPopupsOffer()
    {
        var ready = JsonNode.Parse("""
            {"installed":true,"protocol":3,"version":"3.10.0","hosted":false,
             "features":{"control":true,"choice":true,"cloud":true,"cloud_all":true,"dialogs":true,"hosted":true}}
            """)!;
        Assert.Equal(BrowserSetup.Ready, BrowserHealth.Setup(ready));
        Assert.True(BrowserHealth.OffersChoice(ready));
        Assert.True(BrowserHealth.OffersCloud(ready));
        Assert.True(BrowserHealth.OffersCloudForAll(ready));
        Assert.True(BrowserHealth.RelaysPopups(ready));
        Assert.Null(BrowserHealth.PopupsUpdate(ready, offered: null));
        Assert.Null(BrowserAddOn.Need(ready));
        Assert.True(BrowserAddOn.IsOn(ready));

        var oldPopups = JsonNode.Parse("""
            {"installed":true,"protocol":3,"version":"3.6.2","features":{"control":true,"dialogs":false}}
            """)!;
        Assert.Equal("3.6.2", BrowserHealth.PopupsUpdate(oldPopups, offered: null));
        Assert.Null(BrowserHealth.PopupsUpdate(oldPopups, offered: "3.6.2"));
        Assert.Equal(BrowserAddOnNeed.Outdated, BrowserAddOn.Need(oldPopups));

        var drift = JsonNode.Parse("""
            {"installed":false,"protocol":3,"version":"3.9.0","drift":["CDP signature changed (AttributeError: foo)."]}
            """)!;
        Assert.Equal(BrowserSetup.Drift, BrowserHealth.Setup(drift));
        Assert.Equal("CDP signature changed", BrowserHealth.DriftWords(drift));
        Assert.Equal(BrowserAddOnNeed.Off, BrowserAddOn.Need(drift));
        var copy = BrowserEmptyCopy.AddOnOff(drift);
        Assert.Equal(BrowserEmptyAction.Update, copy.Action);

        Assert.True(BrowserAddOn.VersionAtLeast("3.10.0", "3.9.0"));
        Assert.True(BrowserAddOn.VersionAtLeast("3.10", "3.10.0"));
        Assert.False(BrowserAddOn.VersionAtLeast("3.9.9", "3.10.0"));
        Assert.False(BrowserAddOn.VersionAtLeast("bad", "3.10.0"));
    }

    [Fact]
    public void PendingTypingReconnectLinkMenuReopenBarLayoutAndPreviewRules()
    {
        var pending = new PendingTyping(limit: 2);
        Assert.Equal(PendingTypingOutcome.Ignored, pending.Add(new BrowserInput.Tap(0.5, 0.5)));
        Assert.Equal(PendingTypingOutcome.First, pending.Add(new BrowserInput.Text("a")));
        Assert.Equal(PendingTypingOutcome.Kept, pending.Add(new BrowserInput.Key("Enter")));
        Assert.Equal(PendingTypingOutcome.Full, pending.Add(new BrowserInput.Text("b")));
        Assert.Equal(2, pending.Take().Count);
        Assert.True(pending.IsEmpty);

        Assert.Equal(1.0, BrowserReconnect.Delay(1));
        Assert.Equal(2.0, BrowserReconnect.Delay(2));
        Assert.Equal(4.0, BrowserReconnect.Delay(3));
        Assert.Equal(8.0, BrowserReconnect.Delay(4));
        Assert.Equal(10.0, BrowserReconnect.Delay(5));
        Assert.Equal(10.0, BrowserReconnect.Delay(10));

        Assert.True(BrowserLinkRule.Restored(ConnectionState.Offline, ConnectionState.Open));
        Assert.True(BrowserLinkRule.Restored(ConnectionState.Offline, ConnectionState.Connecting));
        Assert.False(BrowserLinkRule.Restored(ConnectionState.Open, ConnectionState.Open));
        Assert.False(BrowserLinkRule.Restored(ConnectionState.Open, ConnectionState.Offline));

        var online = BrowserMenuRule.ChatItem(offline: false);
        Assert.Null(online.Subtitle);
        Assert.False(online.Disabled);
        var off = BrowserMenuRule.ChatItem(offline: true);
        Assert.Equal("Offline", off.Subtitle);
        Assert.True(off.Disabled);

        Assert.Equal(BrowserViewerReopen.Open, BrowserViewerReopenRule.Decide(null, false, "ivy", true));
        Assert.Equal(BrowserViewerReopen.Front, BrowserViewerReopenRule.Decide("ivy", false, "ivy", true));
        Assert.Equal(BrowserViewerReopen.Replace, BrowserViewerReopenRule.Decide("ivy", false, "wren", true));
        Assert.Equal(BrowserViewerReopen.Ignore, BrowserViewerReopenRule.Decide("ivy", true, "wren", true));
        Assert.Equal(BrowserViewerReopen.Ignore, BrowserViewerReopenRule.Decide("ivy", false, "wren", false));

        // Bar layout stacks when narrow and stays on one line when wide
        Assert.True(BrowserBarLayout.Stacks(accessibility: false, icons: 5 * 40, give: 112, width: 320));
        Assert.False(BrowserBarLayout.Stacks(accessibility: false, icons: 5 * 40, give: 112, width: 500));

        // PreviewTab target parsing & Answer windowing
        var page = Assert.IsType<PreviewTarget.Page>(PreviewTarget.Parse("example.com/guide"));
        Assert.Equal("https://example.com/guide", page.Url.AbsoluteUri);
        Assert.IsType<PreviewTarget.File>(PreviewTarget.Parse("/tmp/report.html"));
        Assert.IsType<PreviewTarget.Unreachable>(PreviewTarget.Parse("http://localhost:3000/app"));
        Assert.IsType<PreviewTarget.Unreachable>(PreviewTarget.Parse("127.0.0.1:8080"));
        Assert.True(PreviewTabRules.Matches(new Uri("https://example.com/guide/"), "https://EXAMPLE.COM/guide"));
        Assert.Equal("example.com", PreviewTabRules.Site(new Uri("https://www.example.com/x")));

        var answerJson = PreviewTabRules.Answer(new PreviewPage("https://example.com", "Docs", "0123456789"), start: 2, count: 4);
        using var answerDoc = JsonDocument.Parse(answerJson);
        Assert.Equal("2345", answerDoc.RootElement.GetProperty("text").GetString());
        Assert.Equal(2, answerDoc.RootElement.GetProperty("start").GetInt32());
        Assert.Equal(6, answerDoc.RootElement.GetProperty("end").GetInt32());
        Assert.Equal(10, answerDoc.RootElement.GetProperty("total_chars").GetInt32());
    }
}
