using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests;

internal static class Fixture
{
    public static JsonNode Load(string name) =>
        JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", name)))!;

    /// A captured frame list → the event frames in it.
    public static IEnumerable<RpcEvent> Events(string name) =>
        Load(name).AsArray().Where(f => f.Str("method") == "event").Select(f => f!["params"]!)
            .Select(p => new RpcEvent(p.Str("type")!, p.Str("session_id") ?? "", p.Get("payload"), p.Int("seq")));
}

public class AddressTests
{
    [Theory]
    [InlineData("studio.local:9119", "http://studio.local:9119")]
    [InlineData("100.101.102.103:9119", "http://100.101.102.103:9119")]
    [InlineData("hermes.example.com", "https://hermes.example.com")]
    [InlineData("https://Host.Example.com/proxy/", "https://host.example.com/proxy")]
    [InlineData("mac-studio:9119", "http://mac-studio:9119")]
    [InlineData("box.tail1234.ts.net", "http://box.tail1234.ts.net")]
    public void NormalizesTypedAddresses(string typed, string expected) =>
        Assert.Equal(expected, GatewayAddress.FromTyped(typed).ToString());

    [Theory]
    [InlineData("http://hermes.example.com", "insecure-url")]
    [InlineData("https://user:pw@host.example.com", "invalid-url")]
    [InlineData("https://host.example.com/?a=1", "invalid-url")]
    [InlineData("", "invalid-url")]
    public void RejectsBadAddresses(string typed, string code) =>
        Assert.Equal(code, Assert.Throws<GatewayException>(() => GatewayAddress.FromTyped(typed)).Code);

    [Fact]
    public void EndpointKeepsBasePathAndEncodesPlus()
    {
        var gw = GatewayAddress.FromTyped("https://host.example.com/hq");
        var url = gw.Endpoint("/api/sessions/a+b/messages", [new("profile", "a+b")]);
        Assert.Equal("https://host.example.com/hq/api/sessions/a+b/messages?profile=a%2Bb", url.AbsoluteUri);
        Assert.Throws<ArgumentException>(() => gw.Endpoint("//evil.example.com/x"));
    }

    [Fact]
    public void SocketUrlPutsTicketLast()
    {
        Assert.Equal("wss://host.example.com/hq/api/ws?profile=default&ticket=t%2B1",
            GatewayAddress.FromTyped("https://host.example.com/hq").SocketUrl("t+1").AbsoluteUri);
        Assert.Equal("ws://127.0.0.1:9711/api/ws?profile=default&ticket=x",
            GatewayAddress.FromTyped("127.0.0.1:9711").SocketUrl("x").AbsoluteUri);
    }
}

public class AuthTests
{
    [Fact]
    public void PkceMatchesRfc7636Shape()
    {
        var p = NousProtocol.NewPkce();
        Assert.Equal(86, p.Verifier.Length);
        Assert.DoesNotContain('=', p.Challenge);
        Assert.Equal(43, p.Challenge.Length);
        Assert.True(NousProtocol.SameState(p.State, p.State));
        Assert.False(NousProtocol.SameState("x", p.State));
    }

    [Fact]
    public void AuthorizeUrlCarriesLoopbackRedirect()
    {
        var p = NousProtocol.NewPkce();
        var url = NousProtocol.AuthorizeUrl(GatewayAddress.FromTyped("https://h.example.com"), p,
            new Uri("http://127.0.0.1:5555/callback"));
        Assert.StartsWith("https://h.example.com/auth/native/authorize?provider=nous&code_challenge=", url.AbsoluteUri);
        Assert.Contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A5555%2Fcallback", url.AbsoluteUri);
    }

    [Fact]
    public void RenewalPolicyFollowsD6()
    {
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1_000_000);
        var tokens = new NousTokens("a", "r", 1_000_000 + 3600, "u", 1_000_000);
        Assert.False(tokens.NeedsRenewal(t0.AddSeconds(1000)));
        Assert.False(tokens.RenewsAlongside(t0.AddSeconds(1000)));
        Assert.True(tokens.RenewsAlongside(t0.AddSeconds(1800)));
        Assert.True(tokens.NeedsRenewal(t0.AddSeconds(3540)));
        Assert.False(tokens with { ExpiresAt = 0 } is var z && z.NeedsRenewal(t0.AddDays(9)));
    }

    [Fact]
    public void SavedAccountsJsonMatchesHermesKit()
    {
        var saved = new SavedAccounts();
        saved.Upsert(new StoredAccount("https://host:10000", "nous:user_abc", Label: "Studio",
            Nous: new NousTokens("A", "R", 1791234567, "user_abc", 1791234000)));
        var json = saved.ToJson();
        Assert.Contains("\"current\":\"https://host:10000\\nnous:user_abc\"", json);
        Assert.Contains("\"accessToken\":\"A\"", json);
        Assert.Contains("\"obtainedAt\":1791234000", json);
        var back = SavedAccounts.FromJson(json);
        Assert.Equal("user_abc", back.CurrentAccount!.Nous!.UserId);
        Assert.True(back.CurrentAccount.IsSignedIn);
    }

    [Theory]
    [InlineData("2026.9.20", true)]
    [InlineData("2026.9.21", false)]
    [InlineData("2026.10.1", false)]
    [InlineData("nonsense", false)]
    public void OutdatedByReleaseDate(string date, bool outdated) =>
        Assert.Equal(outdated, SignIn.IsOutdated(new JsonObject { ["release_date"] = date }));

    [Fact]
    public async Task LoopbackRelayCatchesCallback()
    {
        using var relay = new LoopbackRelay();
        Assert.Equal("127.0.0.1", relay.RedirectUri.Host);
        var wait = relay.WaitAsync(CancellationToken.None);
        using var http = new HttpClient();
        await http.GetStringAsync(new Uri(relay.RedirectUri, "/favicon.ico")); // a stray request doesn't settle it
        Assert.False(wait.IsCompleted);
        var page = await http.GetStringAsync(relay.RedirectUri + "?code=abc&state=s1");
        Assert.Contains("Signed in", page);
        var cb = await wait;
        Assert.Equal("abc", cb.Code);
        Assert.Equal("s1", cb.State);
    }
}

public class RosterTests
{
    [Theory]
    [InlineData("perf-profiles-list.json")]
    [InlineData("demo-profiles-list.json")]
    public void ParsesRoster(string name)
    {
        var bots = Roster.Parse(Fixture.Load(name));
        Assert.NotEmpty(bots);
        Assert.All(bots, b => Assert.False(string.IsNullOrWhiteSpace(b.DisplayName)));
        // Pinned bots come first.
        var firstUnpinned = bots.ToList().FindIndex(b => !b.Pinned);
        Assert.True(firstUnpinned < 0 || bots.Skip(firstUnpinned).All(b => !b.Pinned));
    }

    [Fact]
    public void DefaultIsHermesAndOpensCanonicalChat()
    {
        var hermes = Roster.Parse(Fixture.Load("perf-profiles-list.json")).First(b => b.Name == "default");
        Assert.Equal("Hermes", hermes.DisplayName);
        Assert.Equal("20260929_120000_aabbcc01", hermes.Canonical!.OpenId);
    }

    [Fact]
    public void NotARosterThrows() =>
        Assert.Throws<GatewayException>(() => Roster.Parse(new JsonObject { ["nope"] = 1 }));

    [Theory]
    [InlineData("perf-sidebar.json")]
    [InlineData("demo-sidebar.json")]
    public void ParsesSidebar(string name)
    {
        var s = Sidebar.Parse(Fixture.Load(name));
        Assert.False(s.Recents.Failed);
        Assert.All(s.Recents.Rows, r => Assert.False(string.IsNullOrWhiteSpace(r.Title)));
    }

    [Fact]
    public void FailedSliceIsRetryNotEmpty()
    {
        var s = Sidebar.Parse(JsonNode.Parse("""{"recents":{"failed":true,"retry":true},"cron":{"sessions":[]},"messaging":{"sessions":[]}}"""));
        Assert.True(s.Recents.Failed);
        Assert.False(s.Cron.Failed);
    }
}

public class HistoryTests
{
    [Theory]
    [InlineData("chat/perf-page-latest-24.json")]
    [InlineData("chat/plaid-page-latest-24.json")]
    [InlineData("chat/plaid-page-after-turn.json")]
    public void FoldsPagesIntoTurns(string name)
    {
        var rows = Fixture.Load(name)["messages"]!.AsArray();
        var messages = HistoryFold.Fold(rows);
        Assert.NotEmpty(messages);
        Assert.Equal(messages.Count, messages.Select(m => m.Id).Distinct().Count());
        // Never two assistant bubbles in a row: a turn is one bubble.
        for (var i = 1; i < messages.Count; i++)
            Assert.False(messages[i].Role == Role.Assistant && messages[i - 1].Role == Role.Assistant);
        Assert.All(messages.SelectMany(m => m.Tools), t => Assert.NotEqual(ToolState.Running, t.State));
    }

    [Fact]
    public void ToolRowsFoldIntoTheTurnAndPair()
    {
        var messages = HistoryFold.Fold(Fixture.Load("chat/perf-page-after-turn.json")["messages"]!.AsArray());
        var turn = messages.Last(m => m.Role == Role.Assistant);
        var tools = turn.Tools.ToList();
        Assert.Equal(3, tools.Count);
        Assert.Equal("terminal", tools[0].Name);
        Assert.Equal("printf synthetic-step-0", tools[0].ArgsText);
        Assert.Contains("All done.", turn.Text);
    }

    [Fact]
    public void UsesRowIdOrId()
    {
        var m = HistoryFold.Fold([JsonNode.Parse("""{"role":"user","content":"hi","id":7}"""),
            JsonNode.Parse("""{"role":"assistant","content":[{"type":"text","text":"yo"}],"row_id":8}"""),
            JsonNode.Parse("""{"role":"assistant","content":"x","display_kind":"hidden","id":9}""")]);
        Assert.Equal(["stored-row-7-user", "stored-row-8-assistant"], m.Select(x => x.Id));
        Assert.Equal("yo", m[1].Text);
    }
}

public class TranscriptTests
{
    private static Transcript Streamed(string frames)
    {
        var t = new Transcript();
        t.AddLocalUser("go");
        foreach (var e in Fixture.Events(frames)) t.Apply(e);
        return t;
    }

    [Fact]
    public void StreamsTextAndToolsInOrder()
    {
        var t = Streamed("chat/perf-turn-frames.json");
        Assert.False(t.Busy);
        var reply = t.Messages[^1];
        Assert.Equal(Role.Assistant, reply.Role);
        Assert.False(reply.IsStreaming);
        Assert.Equal("Let me run three steps. All done.", reply.Text);
        Assert.Equal(3, reply.Tools.Count());
        Assert.All(reply.Tools, c => Assert.Equal(ToolState.Done, c.State));
        Assert.IsType<TextPart>(reply.Parts[0]);
        Assert.IsType<ToolPart>(reply.Parts[1]);
    }

    [Fact]
    public void NonStreamingProviderFillsFromComplete()
    {
        var t = new Transcript();
        t.AddLocalUser("hi");
        t.Apply(new RpcEvent("message.start", "s", null, null));
        Assert.Equal(Transcript.Outcome.TurnEnded,
            t.Apply(new RpcEvent("message.complete", "s", JsonNode.Parse("""{"text":"Whole reply","status":"complete"}"""), null)));
        Assert.Equal("Whole reply", t.Messages[^1].Text);
    }

    [Fact]
    public void EmptyCompleteNeverWipesText()
    {
        var t = new Transcript();
        t.AddLocalUser("hi");
        t.Apply(new RpcEvent("message.delta", "s", JsonNode.Parse("""{"text":"partial"}"""), null));
        t.Apply(new RpcEvent("message.complete", "s", JsonNode.Parse("""{"text":""}"""), null));
        Assert.Equal("partial", t.Messages[^1].Text);
    }

    [Fact]
    public void LongStreamWithSeqAndReasoning()
    {
        var t = Streamed("chat/plaid-turn-frames.json");
        var reply = t.Messages[^1];
        Assert.StartsWith("Institution response code", reply.Text);
        Assert.False(t.Busy);
    }

    [Fact]
    public void DuplicateSeqIsDropped()
    {
        var t = new Transcript();
        t.AddLocalUser("hi");
        var d = new RpcEvent("message.delta", "s", JsonNode.Parse("""{"text":"a"}"""), 5);
        t.Apply(d);
        Assert.Equal(Transcript.Outcome.None, t.Apply(d));
        Assert.Equal("a", t.Messages[^1].Text);
    }

    [Fact]
    public void StopSealsAndDropsLateFrames()
    {
        var t = new Transcript();
        t.AddLocalUser("go");
        var frames = Fixture.Events("chat/perf-stop-frames.json").ToList();
        var complete = frames.FindIndex(f => f.Type == "message.complete");
        foreach (var e in frames.Take(complete)) t.Apply(e);
        var shown = t.Messages[^1].Text;
        Assert.StartsWith("word0 word1", shown);
        t.Stop();
        Assert.False(t.Busy);
        Assert.True(t.Messages[^1].Interrupted);
        // The fixture's stand-in "Stopped synthetic reply." doesn't extend the shown text, so it's not drawn.
        foreach (var e in frames.Skip(complete)) t.Apply(e);
        Assert.Equal(shown, t.Messages[^1].Text);
        t.Apply(new RpcEvent("message.delta", "s", JsonNode.Parse("""{"text":"late"}"""), null));
        Assert.Equal(shown, t.Messages[^1].Text);
    }

    [Fact]
    public void CancelledBeforeReadyIsAStop()
    {
        var t = new Transcript();
        t.AddLocalUser("go");
        var o = t.Apply(new RpcEvent("error", "s",
            JsonNode.Parse("""{"message":"Turn cancelled before the agent was ready"}"""), null));
        Assert.Equal(Transcript.Outcome.TurnEnded, o);
        Assert.DoesNotContain(t.Messages, m => m.Role == Role.System);
    }

    [Fact]
    public void AnErrorWithNoTurnInFlightIsAProblemNotARow()
    {
        // [WIN-COMPOSER-CARD-IDS] LiveChatSession+Events.swift: `guard inFlight, !turn.interrupted else { … sessionProblem =
        // SessionProblem.make(…) }`: the chat's card, not an error card in the transcript.
        var t = new Transcript();
        var o = t.Apply(new RpcEvent("error", "s", JsonNode.Parse("""{"message":"Disk is full"}"""), null));
        Assert.Equal(Transcript.Outcome.Problem, o);
        Assert.Equal("Disk is full", t.ProblemText);
        Assert.Empty(t.Messages);
        // The gateway's nested form says the same.
        Assert.Equal(Transcript.Outcome.Problem, t.Apply(new RpcEvent("error", "s",
            JsonNode.Parse("""{"message":{"message":"could not start the assistant"}}"""), null)));
        Assert.Equal("could not start the assistant", t.ProblemText);
    }

    [Fact]
    public void AnErrorAfterStopBeforeItsEndIsNotAProblem()
    {
        // The Mac's `turn.interrupted`: a stopped turn whose terminal frame hasn't come says nothing on the card.
        var t = new Transcript();
        t.AddLocalUser("go");
        t.Apply(new RpcEvent("message.start", "s", null, null));
        t.Stop();
        Assert.Equal(Transcript.Outcome.None, t.Apply(new RpcEvent("error", "s", JsonNode.Parse("""{"message":"Disk is full"}"""), null)));
        Assert.Null(t.ProblemText);
    }

    [Fact]
    public void AnErrorDuringATurnIsStillItsErrorRow()
    {
        var t = new Transcript();
        t.AddLocalUser("go");
        Assert.Equal(Transcript.Outcome.TurnEnded, t.Apply(new RpcEvent("error", "s", JsonNode.Parse("""{"message":"Disk is full"}"""), null)));
        Assert.Contains(t.Messages, m => m.Error == "Disk is full");
        Assert.Null(t.ProblemText);
    }

    [Fact]
    public void HistoryRefreshKeepsLiveTail()
    {
        var t = new Transcript();
        t.ReplaceWithHistory(HistoryFold.Fold([JsonNode.Parse("""{"role":"user","content":"old","id":1}""")]));
        t.AddLocalUser("new question");
        t.Apply(new RpcEvent("message.delta", "s", JsonNode.Parse("""{"text":"stream"}"""), null));
        t.ReplaceWithHistory(HistoryFold.Fold([JsonNode.Parse("""{"role":"user","content":"old","id":1}"""),
            JsonNode.Parse("""{"role":"user","content":"new question","id":2}""")]));
        Assert.Equal(["old", "new question", "stream"], t.Messages.Select(m => m.Text));
    }
}

public class CacheTests
{
    [Fact]
    public void RoundTripsNewestMessagesAndPurges()
    {
        var root = Path.Combine(Path.GetTempPath(), "hqw-cache-" + Guid.NewGuid().ToString("N"));
        try
        {
            var cache = new FileTranscriptCache(root);
            var messages = HistoryFold.Fold(Fixture.Load("chat/perf-page-after-turn.json")["messages"]!.AsArray());
            cache.Write("acct", "default", "20260929_120000_aabbcc01", messages);
            var back = cache.Read("acct", "default", "20260929_120000_aabbcc01")!;
            Assert.Equal(messages.TakeLast(40).Select(m => (m.Id, m.Text, m.Tools.Count())),
                back.Select(m => (m.Id, m.Text, m.Tools.Count())));
            Assert.Null(cache.Read("acct", "default", "other"));
            cache.Purge("acct");
            Assert.Null(cache.Read("acct", "default", "20260929_120000_aabbcc01"));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
