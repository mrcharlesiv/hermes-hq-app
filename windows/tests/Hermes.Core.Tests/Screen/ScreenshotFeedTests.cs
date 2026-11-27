// [WIN-SCREEN-SHOT-FEED] Ports of the web's `bot-activity-model.test.ts` plus the feed's own rules (docs/spec/3x-screen.md
// §5.2, §5.14): the Mac's Tests/Screen/ScreenshotFeedTests.swift at 93f984bb1, case for case (its ScreenshotRulesTests
// and ScreenshotFeedTests suites). The Mac runs the feed on its main actor; here every feed read and call goes through a
// MainLoop, and the feed suite runs alone (its poll-interval case measures real seconds). Waits poll for at least 10 s.

using System.Globalization;
using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Rpc;
using Hermes.Core.Screen;
using static Hermes.Core.Tests.Screen.ScreenWaits;
using F = Hermes.Core.Screen.ScreenshotFeed.FeedState;

namespace Hermes.Core.Tests.Screen;

internal static class ShotRows
{
    public static string Saved(string name) => $"capture mode=som 1920x1080\n  (shareable screenshot saved to /h/.hermes/cache/images/{name})";

    public static JsonObject ToolRow(string id, double at = 1) => new()
    {
        ["role"] = "tool", ["name"] = "computer_use", ["tool_call_id"] = id, ["timestamp"] = at, ["content"] = Saved($"{id}.png"),
    };

    public static string SessionsAnswer(double active) =>
        $$"""{"sessions":[{"id":"s1","last_active":{{active.ToString(CultureInfo.InvariantCulture)}},"cwd":"/Users/x/work"}]}""";

    public static string RowsAnswer(params (string Id, double At)[] ids) =>
        new JsonObject { ["messages"] = new JsonArray(ids.Select(i => (JsonNode)ToolRow(i.Id, i.At)).ToArray()) }.ToJsonString();

    public static JsonNode? N(string json) => JsonNode.Parse(json);
}

internal sealed class Offline : Exception;

public sealed class ScreenshotRulesTests
{
    private static JsonNode? N(string json) => ShotRows.N(json);
    private static List<JsonNode?> Rows(params JsonNode?[] rows) => [.. rows];

    [Fact]
    public void FindsTheNewestScreenshotWithWhatTheBotWasDoing()
    {
        // The gateway answers `order=latest` with its newest rows in chronological order (oldest of them first), as the
        // web app's latestShot reads them: the newest screenshot is the last one in the page.
        var rows = Rows(
            N("""{"role":"user","content":"check the status page"}"""),
            N("""{"role":"assistant","content":"","tool_calls":[{"id":"c1","function":{"name":"computer_use","arguments":"{\"action\":\"capture\"}"}}]}"""),
            new JsonObject { ["role"] = "tool", ["name"] = "computer_use", ["tool_call_id"] = "c1", ["timestamp"] = 100, ["content"] = ShotRows.Saved("computer_use_1.png") },
            N("""{"role":"assistant","content":"","tool_calls":[{"id":"c2","function":{"name":"computer_use","arguments":"{\"action\":\"click\",\"app\":\"Safari\"}"}}]}"""),
            new JsonObject { ["role"] = "tool", ["name"] = "computer_use", ["tool_call_id"] = "c2", ["timestamp"] = 110, ["content"] = ShotRows.Saved("computer_use_2.png") },
            N("""{"role":"assistant","content":"","tool_calls":[{"id":"c3","function":{"name":"terminal","arguments":"{}"}}]}"""),
            N("""{"role":"tool","name":"terminal","tool_call_id":"c3","timestamp":120,"content":"screenshot saved to /tmp/not-a-screen-tool.png"}"""));
        Assert.Equal(new ScreenShot("c2", "/h/.hermes/cache/images/computer_use_2.png", "Clicked in Safari", 110), ScreenshotRules.LatestShot(rows));
        Assert.Equal("c1", ScreenshotRules.LatestShot(rows.Take(3).ToList())?.Id);        // an older page ends with the older capture
        Assert.Null(ScreenshotRules.LatestShot([rows[0]]));
        var browser = N("""{"role":"tool","tool_name":"browser_navigate","tool_call_id":"b1","args":{"url":"https://status.example.com/x"},"content":"{\"screenshot_path\":\"/h/s.png\"}"}""");
        var shot = ScreenshotRules.LatestShot([browser]);
        Assert.Equal("/h/s.png", shot?.Src);
        Assert.Equal("Opened status.example.com", shot?.Caption);
        Assert.Null(shot?.At);
        // No call id: the id is made of the tool and its time (or its place in the page).
        Assert.Equal("computer_use-1791700123", ScreenshotRules.LatestShot(
            [new JsonObject { ["role"] = "tool", ["name"] = "computer_use", ["timestamp"] = 1791700123, ["content"] = ShotRows.Saved("a.png") }])?.Id);
        Assert.Equal("computer_use-1", ScreenshotRules.LatestShot(
            [N("""{"role":"user"}"""), new JsonObject { ["role"] = "tool", ["name"] = "computer_use", ["content"] = ShotRows.Saved("a.png") }])?.Id);
    }

    [Fact]
    public void TakesALiveCaptureStraightFromItsEnvelope()
    {
        var payload = N("""{"name":"computer_use","tool_id":"t9","args":{"action":"type"},"result":{"_multimodal":true,"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}}""");
        Assert.Equal(new ScreenShot("t9", "data:image/png;base64,AAAA", "Typed", 500), ScreenshotRules.LiveShot(payload, 500));
        Assert.Equal("/h/.hermes/cache/images/computer_use_9.png",
            ScreenshotRules.LiveShot(new JsonObject { ["name"] = "computer_use", ["tool_id"] = "t10", ["summary"] = ShotRows.Saved("computer_use_9.png") }, 1)?.Src);
        Assert.Null(ScreenshotRules.LiveShot(N("""{"name":"terminal","result":"x"}"""), 1));
        Assert.Null(ScreenshotRules.LiveShot(N("""{"name":"computer_use","result":"no image"}"""), 1));
        Assert.Equal("browser_vision-77", ScreenshotRules.LiveShot(N("""{"name":"browser_vision","result_text":"Screenshot path: /h/b.png"}"""), 77)?.Id);
    }

    [Fact]
    public void Captions()
    {
        Assert.Equal("Scrolled", ScreenshotRules.ShotCaption("computer_use", JsonValue.Create("""{"action":"scroll"}""")));
        Assert.Equal("Used the computer", ScreenshotRules.ShotCaption("computer_use", new JsonObject()));
        Assert.Equal("Used the computer", ScreenshotRules.ShotCaption("computer_use", null));
        Assert.Equal("Looked at the page", ScreenshotRules.ShotCaption("browser_vision", new JsonObject()));
        Assert.Equal("Used the browser", ScreenshotRules.ShotCaption("browser_frobnicate", new JsonObject()));
        Assert.Equal("Opened a page", ScreenshotRules.ShotCaption("browser_navigate", new JsonObject { ["url"] = "not a url" }));
        Assert.Equal("Opened localhost:8080", ScreenshotRules.ShotCaption("browser_navigate", new JsonObject { ["url"] = "http://localhost:8080/a" }));
        (string, string)[] table =
        [
            ("capture", "Looked at the screen"), ("screenshot", "Looked at the screen"), ("click", "Clicked"), ("left_click", "Clicked"),
            ("double_click", "Double-clicked"), ("right_click", "Right-clicked"), ("middle_click", "Clicked"), ("type", "Typed"),
            ("key", "Pressed keys"), ("hotkey", "Pressed keys"), ("press_key", "Pressed keys"), ("scroll", "Scrolled"),
            ("drag", "Dragged"), ("move", "Moved the pointer"), ("mouse_move", "Moved the pointer"), ("zoom", "Zoomed in"),
            ("wait", "Waited"), ("CLICK", "Clicked"), ("levitate", "Used the computer"),
        ];
        foreach (var (action, words) in table)
            Assert.Equal(words, ScreenshotRules.ShotCaption("computer_use", new JsonObject { ["action"] = action }));
        Assert.Equal("Clicked in Safari", ScreenshotRules.ShotCaption("computer_use_preview", new JsonObject { ["action"] = "click", ["app"] = "Safari" }));
        Assert.Equal("Clicked", ScreenshotRules.ShotCaption("computer_use", new JsonObject { ["action"] = "click", ["app"] = "" }));
        (string, string)[] browser =
        [
            ("browser_screenshot", "Looked at the page"), ("browser_click", "Clicked in the browser"), ("browser_type", "Typed in the browser"),
            ("browser_scroll", "Scrolled the page"), ("browser_snapshot", "Read the page"), ("browser_back", "Went back"),
        ];
        foreach (var (tool, words) in browser) Assert.Equal(words, ScreenshotRules.ShotCaption(tool, null));
    }

    [Fact]
    public void Ages()
    {
        Assert.Equal("", ScreenshotRules.ShotAge(null, 0));
        Assert.Equal("just now", ScreenshotRules.ShotAge(100, 105));
        Assert.Equal("just now", ScreenshotRules.ShotAge(100, 90));
        Assert.Equal("42 s ago", ScreenshotRules.ShotAge(100, 142));
        Assert.Equal("7 min ago", ScreenshotRules.ShotAge(100, 100 + 7 * 60));
        Assert.Equal("5 h ago", ScreenshotRules.ShotAge(100, 100 + 5 * 3600));
        var old = ScreenshotRules.ShotAge(1_791_700_123, 1_791_700_123 + 3 * 86_400, CultureInfo.GetCultureInfo("en-US"), TimeZoneInfo.Utc);
        Assert.Equal("Oct 11", old);
    }

    [Fact]
    public void TellsAMacOrAWindowsGatewayFromThePathsItReports()
    {
        Assert.Equal(ScreenHostKind.Mac, ScreenshotRules.HostKind(["/Users/x/.hermes/cache/images/c.png"]));
        Assert.Equal(ScreenHostKind.Windows, ScreenshotRules.HostKind([null, @"C:\Users\x\hermes"]));
        Assert.Equal(ScreenHostKind.Windows, ScreenshotRules.HostKind(["D:/work"]));
        Assert.Null(ScreenshotRules.HostKind(["data:image/png;base64,AA", "/home/x"]));
        Assert.Equal(ScreenHostKind.Mac, ScreenshotRules.HostKind(["/opt/homebrew/bin"]));
        Assert.Null(ScreenshotRules.HostKind([]));
    }

    [Fact]
    public void HeadingsNameTheBotAndEndTheBlockerWithOnePeriod()
    {
        var plain = ScreenshotRules.Heading(ScreenSession.Fallback.Unsupported, "Hermes", null, null);
        Assert.Equal("Screen sharing isn’t set up on the computer running Hermes", plain.Title);
        Assert.Equal("Instead, Hermes’s latest screenshot shows here and updates while the bot works.", plain.Detail);
        Assert.Equal("Live screen sharing isn’t available on the computer running Hermes",
            ScreenshotRules.Heading(ScreenSession.Fallback.Unsupported, "Hermes", ScreenHostKind.Windows, null).Title);
        var blocked = ScreenshotRules.Heading(ScreenSession.Fallback.Blocked, "Ivy", ScreenHostKind.Mac, "Screen sharing is off on this Mac.");
        Assert.Equal("Screen sharing needs attention", blocked.Title);
        Assert.Equal("Screen sharing is off on this Mac. Meanwhile, Ivy’s latest screenshot shows here.", blocked.Detail);
        Assert.Equal("No display. Meanwhile, Ivy’s latest screenshot shows here.", ScreenshotRules.Heading(ScreenSession.Fallback.Blocked, "Ivy", null, "No display").Detail);
        Assert.Equal("Meanwhile, Ivy’s latest screenshot shows here.", ScreenshotRules.Heading(ScreenSession.Fallback.Blocked, "Ivy", null, null).Detail);
        var old = ScreenshotRules.Heading(ScreenSession.Fallback.Unavailable, "Ivy", null, null);
        Assert.Equal("Screen needs a newer Hermes", old.Title);
        Assert.Equal("Update Hermes on the computer running Hermes to watch live. Meanwhile, Ivy’s latest screenshot shows here.", old.Detail);
        // A Hermes Cloud agent: Nous updates its Hermes, so no update instruction.
        var cloud = ScreenshotRules.Heading(ScreenSession.Fallback.Unavailable, "Ivy", null, null, managed: true);
        Assert.Equal("Screen isn’t on this Hermes Cloud release yet", cloud.Title);
        Assert.DoesNotContain("Update Hermes", cloud.Detail);
        Assert.Equal("Screen sharing needs attention", ScreenshotRules.Heading(ScreenSession.Fallback.Blocked, "Ivy", null, null, managed: true).Title);
    }

    [Fact]
    public void SessionsAreReadNewestActivityFirst()
    {
        var sessions = ScreenshotRules.Sessions("""{"sessions":[{"id":"a","last_active":5,"cwd":"/Users/x"},{"id":"b","last_active":9},{"last_active":99}]}""");
        Assert.Equal(["b", "a"], sessions.Select(s => s.Id));
        Assert.Equal("/Users/x", sessions.Last().Cwd);
        Assert.Single(ScreenshotRules.Rows("""{"messages":[{"role":"user"}]}"""));
    }

    // The poll

    [Fact]
    public async Task ThePollRetriesAFailedReadInsteadOfSettlingOnAFalseEmptyState()
    {
        List<ScreenshotPoller.Empty> states = [];
        List<string> shots = [];
        var fail = true;
        var reads = 0;
        List<int> limits = [];
        var poller = new ScreenshotPoller(() => Task.FromResult<List<RecentScreenSession>>([new("s1", 5)]), (_, limit) =>
        {
            reads += 1;
            limits.Add(limit);
            if (fail) throw new Offline();
            return Task.FromResult<List<JsonNode?>>([ShotRows.ToolRow("c1")]);
        });
        poller.Shot = s => shots.Add(s.Id);
        poller.Emptied = states.Add;
        await poller.PollAsync();
        Assert.Empty(states);
        await poller.PollAsync();
        Assert.Equal([ScreenshotPoller.Empty.Unreachable], states);
        fail = false;
        await poller.PollAsync();
        Assert.Equal(["c1"], shots);
        await poller.PollAsync();
        Assert.Equal(3, reads);                  // the same session, unmoved: no second fetch
        Assert.Equal([40, 40, 40], limits);
    }

    [Fact]
    public async Task ThePollFetchesFewerRowsOnceAScreenshotWasFound()
    {
        var active = 5.0;
        List<int> limits = [];
        var poller = new ScreenshotPoller(() => Task.FromResult<List<RecentScreenSession>>([new("s1", active)]), (_, limit) =>
        {
            limits.Add(limit);
            return Task.FromResult<List<JsonNode?>>([ShotRows.ToolRow("c1")]);
        });
        await poller.PollAsync();
        active = 6;
        await poller.PollAsync();
        Assert.Equal([40, 8], limits);
    }

    [Fact]
    public async Task ThePollSaysNoScreenshotsForABotWithNoSessionsEveryTime()
    {
        List<ScreenshotPoller.Empty> states = [];
        var poller = new ScreenshotPoller(() => Task.FromResult<List<RecentScreenSession>>([]), (_, _) => Task.FromResult<List<JsonNode?>>([]));
        poller.Emptied = states.Add;
        await poller.PollAsync();
        await poller.PollAsync();
        Assert.Equal([ScreenshotPoller.Empty.None, ScreenshotPoller.Empty.None], states);
    }
}

/// The Swift `FakeGatewayClient` as the feed uses it: REST answered by a handler (synchronously, as the Swift fake's),
/// logged with its query, and events the test emits to every subscriber.
internal sealed class FakeShotGateway : IScreenshotGateway
{
    private readonly object _gate = new();
    private readonly List<(string Path, List<KeyValuePair<string, string>> Query)> _restLog = [];
    private readonly List<(IReadOnlySet<string> Types, Action<RpcEvent> Handler)> _subscribers = [];
    private Func<string, IReadOnlyList<KeyValuePair<string, string>>, string> _rest = (_, _) => "{}";

    public void OnRest(Func<string, IReadOnlyList<KeyValuePair<string, string>>, string> answer) { lock (_gate) _rest = answer; }

    public List<(string Path, List<KeyValuePair<string, string>> Query)> RestLog { get { lock (_gate) return [.. _restLog]; } }

    public Task<string> RestAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, CancellationToken ct = default)
    {
        Func<string, IReadOnlyList<KeyValuePair<string, string>>, string> answer;
        lock (_gate)
        {
            _restLog.Add((path, query.ToList()));
            answer = _rest;
        }
        try { return Task.FromResult(answer(path, query)); }
        catch (Exception e) { return Task.FromException<string>(e); }
    }

    public IDisposable RpcEvents(IReadOnlySet<string> types, Action<RpcEvent> handler)
    {
        var entry = (types, handler);
        lock (_gate) _subscribers.Add(entry);
        return new Unsubscribe(() => { lock (_gate) _subscribers.Remove(entry); });
    }

    public void Emit(RpcEvent e)
    {
        List<(IReadOnlySet<string> Types, Action<RpcEvent> Handler)> now;
        lock (_gate) now = [.. _subscribers];
        foreach (var (types, handler) in now) if (types.Contains(e.Type)) handler(e);
    }

    private sealed class Unsubscribe(Action stop) : IDisposable
    {
        public void Dispose() => stop();
    }
}

[CollectionDefinition("ScreenshotFeed", DisableParallelization = true)]
public sealed class ScreenshotFeedCollection;

[Collection("ScreenshotFeed")]
public sealed class ScreenshotFeedTests
{
    private sealed class Rig : IDisposable
    {
        public MainLoop Main { get; } = new();
        public FakeShotGateway Client { get; } = new();
        public ScreenshotFeed Feed { get; }

        public Rig(double now = 1_000)
        {
            Feed = Main.Read(() => new ScreenshotFeed(Client, "default", "Hermes") { Now = () => now, Slow = () => false });
        }

        public T Read<T>(Func<ScreenshotFeed, T> read) => Main.Read(() => read(Feed));
        public void Do(Action<ScreenshotFeed> act) => Main.Run(() => act(Feed));
        public Task Tick() => Main.RunAsync(() => Feed.Tick());
        public F State => Read(f => f.State);
        public ScreenShot? Shot => Read(f => f.Shot);
        public int Polls => Client.RestLog.Count(r => r.Path == "/api/profiles/sessions");

        public void Dispose()
        {
            Do(f => f.Stop());
            Assert.Empty(Main.Failures);
            Main.Dispose();
        }
    }

    private static RpcEvent Event(string type, string session, string payload) => new(type, session, JsonNode.Parse(payload), null);

    [Fact]
    public async Task ShowsTheNewestStoredScreenshotAndPollsOnlyTheSessionsListWhileNothingMoves()
    {
        using var rig = new Rig();
        rig.Client.OnRest((path, _) => path.EndsWith("/messages", StringComparison.Ordinal) ? ShotRows.RowsAnswer(("c1", 900), ("c2", 990)) : ShotRows.SessionsAnswer(5));
        Assert.Equal(F.Searching, rig.State);
        Assert.Equal("Looking for screenshots…", rig.Read(f => f.EmptyLine));
        rig.Do(f => f.SetVisible(true));
        Assert.True(await ScreenWait(() => rig.Shot != null));
        Assert.Equal("c2", rig.Shot?.Id);
        Assert.Equal(F.Loading, rig.State);
        Assert.Equal("Loading the screenshot…", rig.Read(f => f.EmptyLine));
        rig.Do(f => f.Loaded("c2", ok: true));
        Assert.Equal(F.Shown, rig.State);
        Assert.Equal("Used the computer · 10 s ago", rig.Read(f => f.Caption()));
        Assert.Equal(ScreenHostKind.Mac, rig.Read(f => f.HostKind));
        await rig.Tick();
        await rig.Tick();
        Assert.Single(rig.Client.RestLog, r => r.Path.EndsWith("/messages", StringComparison.Ordinal));
        Assert.True(rig.Polls >= 3);
        var query = rig.Client.RestLog.First(r => r.Path == "/api/profiles/sessions").Query;
        var asked = query.ToDictionary(q => q.Key, q => q.Value);
        Assert.Equal(new Dictionary<string, string>
        {
            ["limit"] = "3", ["offset"] = "0", ["min_messages"] = "1", ["archived"] = "exclude", ["order"] = "recent", ["profile"] = "default",
        }, asked);
        // Beyond the Swift case: the messages call names the session and asks for the newest 40 rows of this bot.
        var messages = rig.Client.RestLog.First(r => r.Path.EndsWith("/messages", StringComparison.Ordinal));
        Assert.Equal("/api/sessions/s1/messages", messages.Path);
        Assert.Equal([new("limit", "40"), new("order", "latest"), new("profile", "default")], messages.Query);
    }

    /// Low Power Mode or a hot phone: half as often (DECISION D9, the web's power-aware interval). Windows: battery saver.
    [Fact]
    public async Task PollsHalfAsOftenWhileThePhoneIsSavingPower()
    {
        using var rig = new Rig();
        rig.Client.OnRest((path, _) => path.EndsWith("/messages", StringComparison.Ordinal) ? ShotRows.RowsAnswer(("c1", 900)) : ShotRows.SessionsAnswer(5));
        rig.Do(f => f.Slow = () => true);
        rig.Do(f => f.SetVisible(true));
        Assert.True(await ScreenWait(() => rig.Polls == 1));
        await Task.Delay(TimeSpan.FromSeconds(4.5));
        Assert.Equal(1, rig.Polls);                      // a 3 s poll would have asked again by now
        await Task.Delay(TimeSpan.FromSeconds(3));
        Assert.Equal(2, rig.Polls);                      // the next one comes at 6 s
    }

    [Fact]
    public async Task HiddenItAsksNothing()
    {
        using var rig = new Rig();
        rig.Client.OnRest((_, _) => ShotRows.SessionsAnswer(5));
        await rig.Tick();
        Assert.Empty(rig.Client.RestLog);
        rig.Do(f => f.SetVisible(true));
        Assert.True(await ScreenWait(() => rig.Client.RestLog.Count > 0));
        rig.Do(f => f.SetVisible(false));
        var before = rig.Client.RestLog.Count;
        await rig.Tick();
        await Task.Delay(150);
        Assert.Equal(before, rig.Client.RestLog.Count);
    }

    [Fact]
    public async Task ALiveToolShowsItsWorkingCaptionThenItsPictureWithoutABlank()
    {
        using var rig = new Rig();
        rig.Client.OnRest((path, _) => path.EndsWith("/messages", StringComparison.Ordinal) ? ShotRows.RowsAnswer(("c1", 900)) : ShotRows.SessionsAnswer(5));
        var announced = 0;
        rig.Do(f => f.OnNewShot = () => announced += 1);
        rig.Do(f => f.IsMine = e => e.SessionId == "ab12cd34");
        rig.Do(f => f.SetVisible(true));
        Assert.True(await ScreenWait(() => rig.Shot != null));
        rig.Do(f => f.Loaded("c1", ok: true));
        rig.Do(f => f.Handle(Event("tool.start", "ab12cd34", """{"name":"computer_use","args":{"action":"click","app":"Safari"}}""")));
        Assert.Equal("Clicked in Safari", rig.Read(f => f.Working));
        Assert.Equal("Clicked in Safari… · 1 min ago", rig.Read(f => f.Caption()));
        // Somebody else's session: nothing.
        rig.Do(f => f.Handle(Event("tool.complete", "ffff0000", """{"name":"computer_use","tool_id":"x","result":{"screenshot_path":"/h/x.png"}}""")));
        Assert.Equal("c1", rig.Shot?.Id);
        rig.Do(f => f.Handle(Event("tool.complete", "ab12cd34",
            """{"name":"computer_use","tool_id":"c9","args":{"action":"click","app":"Safari"},"result":{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}}""")));
        Assert.Equal("c9", rig.Shot?.Id);
        Assert.Equal(F.Shown, rig.State);                // the old picture stayed up; the inline one needs no load
        Assert.Equal("", rig.Read(f => f.Working));
        Assert.Equal("Clicked in Safari · just now", rig.Read(f => f.Caption()));
        Assert.Equal(1, rig.Main.Read(() => announced));
        // The same capture arriving by REST after its live event does not replace it; an older one neither.
        rig.Do(f => f.Handle(Event("tool.complete", "ab12cd34", """{"name":"computer_use","tool_id":"c9","result":{"screenshot_path":"/h/c9.png"}}""")));
        Assert.Equal("data:image/png;base64,AAAA", rig.Shot?.Src);
        Assert.Equal(1, rig.Main.Read(() => announced));
    }

    [Fact]
    public async Task EventsArriveThroughTheClientAndStoredSessionsCount()
    {
        using var rig = new Rig();
        rig.Client.OnRest((path, _) => path.EndsWith("/messages", StringComparison.Ordinal) ? ShotRows.RowsAnswer() : ShotRows.SessionsAnswer(5));
        rig.Do(f => f.SetVisible(true));
        Assert.True(await ScreenWait(() => rig.State == F.None));
        Assert.Equal("No screenshots yet. When Hermes uses its computer or browser, the newest one appears here.", rig.Read(f => f.EmptyLine));
        rig.Client.Emit(Event("tool.complete", "99990000",
            """{"name":"browser_vision","tool_id":"b1","stored_session_id":"s1","result":{"screenshot_path":"/Users/x/b1.png"}}"""));
        Assert.True(await ScreenWait(() => rig.Shot?.Id == "b1"));
        Assert.Equal(F.Loading, rig.State);
        rig.Do(f => f.Loaded("b1", ok: false));
        Assert.Equal(F.Expired, rig.State);
        Assert.Equal("This screenshot has expired: the gateway keeps only its 20 most recent screenshots.", rig.Read(f => f.EmptyLine));
        rig.Do(f => f.Loaded("someone-else", ok: true));
        Assert.Equal(F.Expired, rig.State);
    }

    /// Review finding 5: a picture that could not be fetched is not an expired capture, and is tried again.
    [Fact]
    public async Task AFailedDownloadIsRetriedAndOnlyAMissingFileIsExpired()
    {
        // URLError(.networkConnectionLost) / URLError(.timedOut): the transport's own errors.
        Assert.True(!ScreenshotFeed.IsGone(new HttpRequestException("The network connection was lost.")) && !ScreenshotFeed.IsGone(new TaskCanceledException("The request timed out.")));
        Assert.True(!ScreenshotFeed.IsGone(new GatewayException("http", "The gateway answered 502.", 502)) && !ScreenshotFeed.IsGone(new GatewayException("http", "The gateway answered 500.", 500)));
        Assert.True(ScreenshotFeed.IsGone(new GatewayException("http", "The gateway answered 404.", 404)) && ScreenshotFeed.IsGone(new GatewayException("http", "The gateway answered 410.", 410)));

        using var rig = new Rig();
        rig.Client.OnRest((path, _) => path.EndsWith("/messages", StringComparison.Ordinal) ? ShotRows.RowsAnswer() : ShotRows.SessionsAnswer(5));
        rig.Do(f => f.SetVisible(true));
        Assert.True(await ScreenWait(() => rig.State == F.None));
        rig.Client.Emit(Event("tool.complete", "99990000",
            """{"name":"browser_vision","tool_id":"b1","stored_session_id":"s1","result":{"screenshot_path":"/Users/x/b1.png"}}"""));
        Assert.True(await ScreenWait(() => rig.Read(f => f.Shot?.Id == "b1" && f.State == F.Loading)));
        rig.Do(f => f.Stop());                                       // the poll loop is out of the way: every step below is the test's
        var attempt = rig.Read(f => f.LoadAttempt);
        rig.Do(f => f.LoadFailed("b1"));                             // what the view reports for a thrown URLError
        Assert.Equal(F.Unloadable, rig.State);
        Assert.Equal("Can’t load the screenshot. Trying again…", rig.Read(f => f.EmptyLine));
        rig.Do(f => f.RetryDue());                                   // after the next poll: the view is asked to fetch it again
        Assert.True(rig.Read(f => f.LoadAttempt == attempt + 1 && f.State == F.Unloadable));
        rig.Do(f => f.LoadFailed("someone-else"));
        Assert.Equal(F.Unloadable, rig.State);
        rig.Do(f => f.Loaded("b1", ok: true));                       // the retry worked
        Assert.Equal(F.Shown, rig.State);
        var settled = rig.Read(f => f.LoadAttempt);
        rig.Do(f => f.RetryDue());
        Assert.Equal(settled, rig.Read(f => f.LoadAttempt));         // a shown picture is not fetched again

        // After the quick tries, only every tenth poll asks again.
        for (var i = 0; i <= ScreenshotFeed.QuickLoadTries; i++) rig.Do(f => f.LoadFailed("b1"));
        var before = rig.Read(f => f.LoadAttempt);
        for (var i = 0; i < 9; i++) rig.Do(f => f.RetryDue());
        Assert.Equal(before, rig.Read(f => f.LoadAttempt));
        rig.Do(f => f.RetryDue());
        Assert.Equal(before + 1, rig.Read(f => f.LoadAttempt));
        rig.Do(f => f.Loaded("b1", ok: false));                      // the gateway answered 404: now it is expired
        Assert.Equal(F.Expired, rig.State);
    }

    [Fact]
    public async Task UnreachableShowsAfterTwoFailedPollsAndThePictureComesBackByItself()
    {
        using var rig = new Rig();
        var down = true;
        rig.Client.OnRest((path, _) =>
        {
            if (Volatile.Read(ref down)) throw new Offline();
            return path.EndsWith("/messages", StringComparison.Ordinal) ? ShotRows.RowsAnswer(("c1", 995)) : ShotRows.SessionsAnswer(5);
        });
        rig.Do(f => f.SetVisible(true));
        Assert.True(await ScreenWait(() => rig.Client.RestLog.Count >= 1));
        Assert.Equal(F.Searching, rig.State);
        for (var i = 0; i < 40 && rig.State != F.Unreachable; i++)
        {
            await rig.Tick();
            await Task.Delay(50);
        }
        Assert.Equal(F.Unreachable, rig.State);
        Assert.Equal("Can’t reach the gateway to look for screenshots. Trying again…", rig.Read(f => f.EmptyLine));
        Volatile.Write(ref down, false);
        for (var i = 0; i < 40 && rig.Shot == null; i++)
        {
            await rig.Tick();
            await Task.Delay(50);
        }
        Assert.Equal("c1", rig.Shot?.Id);
    }

    // Beyond the Swift cases: the C# wiring the Swift gets from its client and its main actor.

    /// Only `tool.start` / `tool.complete` are asked for; a stopped feed reads no more events.
    [Fact]
    public async Task AStoppedFeedReadsNoMoreEvents()
    {
        using var rig = new Rig();
        rig.Client.OnRest((path, _) => path.EndsWith("/messages", StringComparison.Ordinal) ? ShotRows.RowsAnswer() : ShotRows.SessionsAnswer(5));
        Assert.Equal(["tool.complete", "tool.start"], ScreenshotFeed.EventTypes.Order(StringComparer.Ordinal));
        rig.Do(f => f.SetVisible(true));
        Assert.True(await ScreenWait(() => rig.State == F.None));
        rig.Do(f => f.Stop());
        rig.Client.Emit(Event("tool.complete", "99990000",
            """{"name":"browser_vision","tool_id":"b1","stored_session_id":"s1","result":{"screenshot_path":"/Users/x/b1.png"}}"""));
        await Task.Delay(100);
        Assert.Null(rig.Shot);
    }

    [Fact]
    public void ASessionIdIsEncodedAsOnePathSegment()
    {
        Assert.Equal("s1", ScreenshotRules.EncodePathSegment("s1"));
        Assert.Equal("a%2Fb%3Fc%23d%20e:f@g", ScreenshotRules.EncodePathSegment("a/b?c#d e:f@g"));
        Assert.Equal("%C3%A9", ScreenshotRules.EncodePathSegment("é"));
    }
}
