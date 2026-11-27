using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Questions;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests;

/// Stands in for the account's socket: records every call and answer frame.
internal sealed class FakeQuestionTransport : IQuestionTransport
{
    public readonly ConcurrentQueue<(string Method, JsonObject Params)> Calls = new();
    public readonly ConcurrentQueue<JsonObject> Frames = new();
    public Func<string, JsonObject, JsonNode> Answer = (_, _) => new JsonObject();
    public bool DeclinesNotShown { get; set; } = true;
    public bool Connected { get; set; } = true;
    public int Epoch { get; set; } = 1;
    public JsonNode? Config { get; set; }

    public Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout)
    {
        if (!Connected) throw new GatewayException("offline", "Not connected to the gateway.");
        Calls.Enqueue((method, (JsonObject)parameters.DeepClone()));
        return Task.FromResult(Answer(method, parameters));
    }

    public Task<int> RespondAsync(string id, JsonNode result)
    {
        if (!Connected) throw new GatewayException("offline", "Not connected to the gateway.");
        Frames.Enqueue(ServerRequestFrames.Response(id, result));
        return Task.FromResult(Epoch);
    }

    public Task<int> FailAsync(string id, int code, string message)
    {
        if (!Connected) throw new GatewayException("offline", "Not connected to the gateway.");
        Frames.Enqueue(ServerRequestFrames.ErrorResponse(id, code, message));
        return Task.FromResult(Epoch);
    }

    public Task<JsonNode?> ConfigAsync(string? profile) => Task.FromResult(Config);
    public void ReconnectNow() { }
}

public class QuestionFrameTests
{
    [Fact]
    public void AnswerFramesHaveTheRequestIdAndNoMethod()
    {
        Assert.Equal("""{"jsonrpc":"2.0","id":"srq-0c51a9e2b8f4","result":{"choice":"once"}}""",
            ServerRequestFrames.Response("srq-0c51a9e2b8f4", new JsonObject { ["choice"] = "once" }).ToJsonString());
        Assert.Equal("""{"jsonrpc":"2.0","id":"srq-77aa01bb22cc","result":{}}""",
            ServerRequestFrames.Response("srq-77aa01bb22cc", new JsonObject()).ToJsonString());
        Assert.Equal("""{"jsonrpc":"2.0","id":"srq-1","error":{"code":4404,"message":"This window is not showing the session."}}""",
            ServerRequestFrames.ErrorResponse("srq-1", 4404, QuestionCenter.NotShownMessage).ToJsonString());
        Assert.Equal("""{"jsonrpc":"2.0","id":"srq-2","error":{"code":-32601,"message":"no handler for server request: setup_choose"}}""",
            ServerRequestFrames.ErrorResponse("srq-2", -32601, "no handler for server request: setup_choose").ToJsonString());
    }

    private const string Resume = """
        {"session_id":"5cc537d1","running":true,
         "open_requests":[
           {"id":"srq-77aa01bb22cc","method":"clarify","params":{"session_id":"5cc537d1","questions":[{"qid":"q0","question":"Which branch?","choices":["main (Recommended)","staging"],"multi_select":false}],"answers":{"q0":"main"}}},
           {"id":"srq-0c51a9e2b8f4","method":"approval","params":{"command":"git push --force origin main","request_id":"9b1d"}}],
         "pending_approval":{"request_id":"9b1d","command":"git push --force origin main","choices":["once","deny"]}}
        """;

    [Fact]
    public void ResumeResultReDeliversOpenRequestsBeforeTheAuthoritativeSet()
    {
        var items = OpenRequestsIntercept.Events("session.resume", new JsonObject { ["session_id"] = "stored" },
            JsonNode.Parse(Resume), 3);
        Assert.Equal(3, items.Count);
        var first = Assert.IsType<ServerRequest>(items[0]);
        Assert.Equal(("srq-77aa01bb22cc", "clarify", "5cc537d1", true, 3), (first.Id, first.Method, first.SessionId, first.Replayed, first.Epoch));
        var second = Assert.IsType<ServerRequest>(items[1]);
        Assert.Equal("5cc537d1", second.SessionId); // params without session_id: the result's
        var open = Assert.IsType<OpenRequests>(items[2]);
        Assert.Equal(["srq-77aa01bb22cc", "srq-0c51a9e2b8f4"], open.Ids);
        Assert.Equal("9b1d", open.PendingApproval.Str("request_id"));
        Assert.Equal("session.resume", open.Method);
        Assert.Null(open.PromptIds);
    }

    [Fact]
    public void AMissingKeyMeansNoneOpen()
    {
        var items = OpenRequestsIntercept.Events("session.events.since", new JsonObject { ["session_id"] = "rt" },
            JsonNode.Parse("""{"events":[],"truncated":false}"""), 1);
        var open = Assert.IsType<OpenRequests>(Assert.Single(items));
        Assert.Empty(open.Ids);
        Assert.Equal("rt", open.SessionId);
        Assert.Null(open.PendingApproval);
        Assert.Empty(OpenRequestsIntercept.Events("prompt.submit", new JsonObject(), JsonNode.Parse(Resume), 1));
    }

    [Fact]
    public void AnAuthoritySnapshotsPromptsComeBackAsClarifyRequests()
    {
        var items = OpenRequestsIntercept.Events("session.resume", new JsonObject(), JsonNode.Parse(
            """{"session_id":"rt","prompts":[{"kind":"clarify","prompt_id":"p1","execution_generation":4,"question":"Why?"},{"kind":"approval","prompt_id":"p2"}]}"""), 1);
        var ev = Assert.IsType<RpcEvent>(items[0]);
        Assert.Equal(("clarify.request", "rt"), (ev.Type, ev.SessionId));
        Assert.Equal(["p1"], Assert.IsType<OpenRequests>(items[1]).PromptIds);
    }
}

public class PromptLogicTests
{
    private static readonly JsonNode Ask = JsonNode.Parse("""
        [{"qid":"q0","question":"Which branch should I deploy?","choices":["main (Recommended)","staging"],"multi_select":false},
         {"qid":"q1","question":"Anything to skip?","choices":["Tests","Lint","Docs"],"multi_select":true},
         {"qid":"q2","question":"What should the release be called?","choices":null,"multi_select":false},
         {"qid":" ","question":"dropped"},
         {"qid":"q3","question":"  Open  ","choices":["  "],"multi_select":true}]
        """)!;

    [Fact]
    public void NormalizesQuestions()
    {
        var q = ClarifyText.Normalize(Ask);
        Assert.Equal(4, q.Count);
        Assert.Equal(["main (Recommended)", "staging"], q[0].Choices!);
        Assert.True(q[1].MultiSelect);
        Assert.Null(q[2].Choices);
        Assert.Equal(("q3", "Open", false), (q[3].Qid, q[3].Question, q[3].MultiSelect));
        Assert.Null(q[3].Choices);
        Assert.Equal("main", ClarifyText.BareChoice("main (Recommended)"));
        Assert.True(ClarifyText.IsRecommended("main (Recommended)"));
    }

    [Fact]
    public void StagesAnswersAsTheWebCardSendsThem()
    {
        var q = ClarifyText.Normalize(Ask);
        Assert.Null(ClarifyStaging.StagedAnswer(q[0]));
        var picked = ClarifyStaging.Toggle(q[0], ClarifyStage.Empty, "main (Recommended)");
        Assert.Equal("main", ClarifyStaging.StagedAnswer(q[0], picked));
        // Single-select: a second tap replaces; Something else drops the pick.
        Assert.Equal(["staging"], ClarifyStaging.Toggle(q[0], picked, "staging").Choices);
        var other = ClarifyStaging.OpenOther(q[0], picked) with { Draft = " canary " };
        Assert.Equal("canary", ClarifyStaging.StagedAnswer(q[0], other));
        // Multi-select: toggles, plus the typed text, as a JSON array string.
        var multi = ClarifyStaging.Toggle(q[1], ClarifyStaging.Toggle(q[1], ClarifyStage.Empty, "Lint"), "Tests");
        multi = ClarifyStaging.Toggle(q[1], multi, "Tests");
        multi = ClarifyStaging.OpenOther(q[1], multi) with { Draft = "skip the changelog" };
        Assert.Equal("""["Lint","skip the changelog"]""", ClarifyStaging.StagedAnswer(q[1], multi));
        Assert.Equal("v2/final", ClarifyStaging.StagedAnswer(q[2], ClarifyStage.Empty with { Draft = " v2/final " }));
        var rows = ClarifyStaging.SentRows(q.Take(3).ToList(), new Dictionary<string, ClarifyStage> { ["q0"] = picked, ["q1"] = multi });
        Assert.Equal([new SentClarifyRow("Which branch should I deploy?", "main"),
            new SentClarifyRow("Anything to skip?", "Lint, skip the changelog"),
            new SentClarifyRow("What should the release be called?", null)], rows);
        Assert.All(ClarifyStaging.SentRows(q, new Dictionary<string, ClarifyStage>(), skipped: true), r => Assert.Equal("", r.Answer));
    }

    [Fact]
    public void ReplayedLocksFillUntouchedQuestions()
    {
        var q = ClarifyText.Normalize(Ask);
        var prompt = new ClarifyPrompt("srq-1", q, new Dictionary<string, string?>
            { ["q0"] = "main", ["q1"] = """["Docs","more"]""", ["q2"] = null }, false);
        var draft = ClarifyStaging.InitialDraft(prompt, new ClarifyDraft(9, new Dictionary<string, ClarifyStage>
            { ["q0"] = new(["staging"]) }));
        Assert.Equal(3, draft.Page); // clamped to the last page
        Assert.Equal(["staging"], draft.Stages["q0"].Choices); // local picks win
        Assert.Equal(["Docs"], draft.Stages["q1"].Choices);
        Assert.Equal(("more", true), (draft.Stages["q1"].Draft, draft.Stages["q1"].Other));
        Assert.False(draft.Stages.ContainsKey("q2"));
    }

    [Theory]
    [InlineData(300, 0, "Expires within 5 min")]
    [InlineData(300, 209, "Expires within 2 min")]
    [InlineData(300, 210, "Expires within 1:30")]
    [InlineData(300, 258, "Expires within 0:42")]
    [InlineData(300, 300, "Expired")]
    [InlineData(7200, 0, "Expires within 2 h")]
    [InlineData(5940, 0, "Expires within 99 min")]
    public void ExpiryLabels(int timeout, int elapsed, string expected)
    {
        var seen = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        Assert.Equal(expected, ApprovalExpiry.Label(seen, TimeSpan.FromSeconds(timeout), seen.AddSeconds(elapsed)));
    }

    [Fact]
    public void ExpiryReadsTheConfigAndHoldsAtZeroUntilAFreshRead()
    {
        Assert.Equal(TimeSpan.FromSeconds(300), ApprovalExpiry.Timeout(JsonNode.Parse("""{"approvals":{"timeout":0}}""")));
        Assert.Equal(TimeSpan.FromSeconds(60), ApprovalExpiry.Timeout(JsonNode.Parse("""{"approvals":{"timeout":60}}""")));
        var seen = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var (label, stale) = ApprovalExpiry.Countdown(seen, TimeSpan.FromSeconds(60), seen, seen.AddSeconds(61));
        Assert.Equal(("Expires within 0:00", true), (label, stale));
        Assert.Equal("Expired", ApprovalExpiry.Countdown(seen, TimeSpan.FromSeconds(60), seen.AddSeconds(61), seen.AddSeconds(61)).Label);
    }

    [Fact]
    public void SheetWordsAndAnswers()
    {
        var sudo = PromptSheetCopy.Make(new ValuePrompt("srq-1", PromptKind.Sudo, new JsonObject { ["command"] = "" }, false), "Ivy");
        Assert.Equal("Administrator Password", sudo.Title);
        Assert.Equal("Ivy didn’t say which command. Choose Don’t Send if you can’t check it in the conversation.", sudo.CommandMissing);
        Assert.Equal(("Send", "Don’t Send", "Password requested"), (sudo.Primary, sudo.Decline, sudo.Chip));
        var secret = PromptSheetCopy.Make(new ValuePrompt("srq-2", PromptKind.Secret,
            new JsonObject { ["env_var"] = "OPENWEATHER_API_KEY", ["prompt"] = "Paste your OpenWeather API key" }, false));
        Assert.Equal(("Your Bot Needs a Key", "OPENWEATHER_API_KEY requested", "OPENWEATHER_API_KEY"), (secret.Title, secret.Chip, secret.Fields[0].Placeholder));
        var login = PromptSheetCopy.Make(new ValuePrompt("srq-3", PromptKind.VaultSaveLogin,
            new JsonObject { ["origin"] = "https://shop.example.com", ["site"] = "www.Example Shop" }, false));
        Assert.Equal(("Save Your Example Shop Login?", "Save and Sign In", "Save login for Example Shop?"), (login.Title, login.Primary, login.Chip));
        Assert.Equal("""{"identifier":"me@example.com","password":"p w"}""",
            PromptSheetCopy.Answer(PromptKind.VaultSaveLogin, [" me@example.com ", "p w"]));
        Assert.Null(PromptSheetCopy.Answer(PromptKind.VaultSaveLogin, ["me", ""]));
        Assert.Equal("123456", PromptSheetCopy.Answer(PromptKind.VaultCode, ["123 45-6"]));
        Assert.Null(PromptSheetCopy.Answer(PromptKind.Secret, [""]));
    }
}

public class QuestionCenterTests
{
    private static readonly QuestionCenter.Timing Fast = new()
    {
        ProbeDebounce = TimeSpan.FromMilliseconds(10), StaleDrop = TimeSpan.FromMilliseconds(100),
        UndeliveredAfter = TimeSpan.FromMilliseconds(50), Leaving = TimeSpan.Zero,
    };

    private static (QuestionCenter, FakeQuestionTransport, ChatQuestions) Make()
    {
        var t = new FakeQuestionTransport();
        var center = new QuestionCenter(t, Fast);
        var link = center.Link("deploys");
        link.Observing = false;
        link.Bind("rt1", "stored1");
        return (center, t, link);
    }

    private static ServerRequest Srq(string id, string method, string json, int epoch = 1, bool replayed = false)
    {
        var p = (JsonObject)JsonNode.Parse(json)!;
        p["session_id"] ??= "rt1";
        return new ServerRequest(id, method, p, p.Str("session_id")!, replayed, epoch);
    }

    private static async Task Until(Func<bool> condition)
    {
        var until = DateTime.UtcNow.AddSeconds(10); // generous: the Windows build machine is slower than a Mac
        while (!condition() && DateTime.UtcNow < until) await Task.Delay(10);
        Assert.True(condition());
    }

    [Fact]
    public async Task ApprovalShowsAndIsAnsweredOnce()
    {
        var (center, t, link) = Make();
        var changes = 0;
        link.Changed += () => Interlocked.Increment(ref changes);
        var told = new List<NeedsInput?>();
        center.NeedsInputChanged += (_, profile, stored, kind) => { Assert.Equal(("deploys", "stored1"), (profile, stored)); told.Add(kind); };
        center.Delivered(Srq("srq-a", "approval", """{"command":"git push --force origin main","description":"git force push","request_id":"r1","choices":["once","session","always","deny"]}"""));
        var a = Assert.Single(link.Prompts.Approvals);
        Assert.Equal(("git push --force origin main", true, true, "r1"), (a.Command, a.AllowSession, a.AllowAlways, a.ClockKey));
        Assert.Equal(NeedsInput.Approval, link.Prompts.NeedsInput);
        Assert.True(changes > 0);

        await link.AnswerApprovalAsync("srq-a", ApprovalChoice.Once);
        await link.AnswerApprovalAsync("srq-a", ApprovalChoice.Once); // a second tap sends nothing
        Assert.Equal("""{"jsonrpc":"2.0","id":"srq-a","result":{"choice":"once"}}""", Assert.Single(t.Frames).ToJsonString());
        await Until(() => link.Prompts.Approvals.Count == 0);
        Assert.Equal([NeedsInput.Approval, null], told);
        // A stale re-delivery on the same socket is ignored; on a later socket Hermes never saw the answer.
        center.Delivered(Srq("srq-a", "approval", """{"command":"x"}""", epoch: 1, replayed: true));
        Assert.Empty(link.Prompts.Approvals);
        center.Delivered(Srq("srq-a", "approval", """{"command":"x"}""", epoch: 2, replayed: true));
        Assert.Single(link.Prompts.Approvals);
    }

    [Fact]
    public void SmartDeniedOffersOnceAndDenyOnly()
    {
        var (center2, _, link2) = Make();
        center2.Delivered(Srq("srq-b", "approval", """{"command":"rm -rf ./build/cache","smart_denied":true}"""));
        var a = Assert.Single(link2.Prompts.Approvals);
        Assert.False(a.AllowSession || a.AllowAlways);
        center2.Delivered(Srq("srq-c", "approval", """{"command":"<browser_exec> (plugin approval rule)","description":"Open a page"}"""));
        Assert.True(link2.Prompts.Approvals[1].ShowsDescription);
        Assert.Equal(2, link2.Prompts.ApprovalStackTotal);
    }

    [Fact]
    public async Task ClarifyLocksEachQuestionInOrderThenSkipIsAnEmptyResult()
    {
        var (center, t, link) = Make();
        t.Answer = (m, _) => m == "clarify.lock" ? JsonNode.Parse("""{"status":"ok","remaining":[]}""")! : new JsonObject();
        center.Delivered(Srq("srq-q", "clarify", """{"questions":[{"qid":"q0","question":"Which branch?","choices":["main (Recommended)","staging"],"multi_select":false},{"qid":"q1","question":"Name?","choices":null}]}"""));
        var clarify = link.Prompts.Clarify!;
        Assert.Equal(NeedsInput.Reply, link.Prompts.NeedsInput);
        Assert.Equal(2, clarify.Questions.Count);
        link.SaveClarifyDraft("srq-q", new ClarifyDraft(1, new Dictionary<string, ClarifyStage> { ["q0"] = new(["main (Recommended)"]) }));
        await link.SendClarifyAsync("srq-q", [("q0", "main"), ("q1", null)]);
        var locks = t.Calls.Where(c => c.Method == "clarify.lock").Select(c => c.Params.ToJsonString()).ToList();
        Assert.Equal([
            """{"request_id":"srq-q","question_id":"q0","answer":"main","profile":"deploys"}""",
            """{"request_id":"srq-q","question_id":"q1","answer":null,"profile":"deploys"}"""], locks);
        Assert.Empty(t.Frames); // the last lock resolves the wait: no response frame
        Assert.Null(link.Prompts.Clarify);
        Assert.Equal([new SentClarifyRow("Which branch?", "main"), new SentClarifyRow("Name?", null)], link.Prompts.SentClarify!.Rows);
        Assert.Null(link.ClarifyDraft("srq-q"));
        // The clarify tool's end clears the note.
        center.Receive(new RpcEvent("tool.complete", "rt1", JsonNode.Parse("""{"name":"clarify"}"""), 9));
        Assert.Null(link.Prompts.SentClarify);

        center.Delivered(Srq("srq-r", "clarify", """{"questions":[{"qid":"q0","question":"Again?"}]}"""));
        await link.SkipClarifyAsync("srq-r");
        Assert.Equal("""{"jsonrpc":"2.0","id":"srq-r","result":{}}""", Assert.Single(t.Frames).ToJsonString());
        Assert.Equal("", link.Prompts.SentClarify!.Rows[0].Answer);
    }

    [Fact]
    public async Task ValuePromptsAnswerValueAndKeepTheirSheetWhenOffline()
    {
        var (center, t, link) = Make();
        center.Delivered(Srq("srq-s", "secret", """{"env_var":"OPENWEATHER_API_KEY","prompt":"Paste"}"""));
        var v = Assert.Single(link.Prompts.Values);
        Assert.Equal((PromptKind.Secret, NeedsInput.Approval), (v.Kind, link.Prompts.NeedsInput));
        t.Connected = false;
        var offline = await Assert.ThrowsAsync<PromptAnswerException>(() => link.AnswerValueAsync("srq-s", "k-123"));
        Assert.True(offline.Offline);
        Assert.Equal(QuestionCenter.Offline, offline.Message);
        Assert.False(Assert.Single(link.Prompts.Values).Sending); // open again
        t.Connected = true;
        await link.AnswerValueAsync("srq-s", "k-123");
        Assert.Equal("""{"jsonrpc":"2.0","id":"srq-s","result":{"value":"k-123"}}""", Assert.Single(t.Frames).ToJsonString());
        Assert.Empty(link.Prompts.Values);
        center.Delivered(Srq("srq-u", "sudo", """{"command":""}"""));
        await link.AnswerValueAsync("srq-u", ""); // Don't Send
        Assert.EndsWith("""{"value":""}}""", t.Frames.Last().ToJsonString());
    }

    [Fact]
    public async Task WindowPanesAreDeclinedAndUnknownMethodsRefused()
    {
        var (center, t, link) = Make();
        center.Delivered(Srq("srq-t", "terminal.read", """{"start":0,"count":50}"""));
        center.Delivered(Srq("srq-x", "setup_choose", """{"kind":"provider"}"""));
        await Until(() => t.Frames.Count == 2);
        var frames = t.Frames.Select(f => f.ToJsonString()).OrderBy(s => s).ToList();
        Assert.Contains("""{"jsonrpc":"2.0","id":"srq-t","error":{"code":4404,"message":"This window is not showing the session."}}""", frames);
        Assert.Contains("""{"jsonrpc":"2.0","id":"srq-x","error":{"code":-32601,"message":"no handler for server request: setup_choose"}}""", frames);
        Assert.True(link.Prompts.IsEmpty);
        // Without declines_not_shown, the pane request gets no frame at all.
        t.DeclinesNotShown = false;
        center.Delivered(Srq("srq-t2", "tour", """{}"""));
        await Task.Delay(50);
        Assert.Equal(2, t.Frames.Count);
        // A clarify with nothing usable is answered {} at once.
        center.Delivered(Srq("srq-e", "clarify", """{"questions":[{"qid":"","question":"x"}]}"""));
        await Until(() => t.Frames.Count == 3);
        Assert.Null(link.Prompts.Clarify);
    }

    [Fact]
    public void WithdrawalsAndTheAuthoritativeSetPrune()
    {
        var (center, _, link) = Make();
        var timedOut = new List<string>();
        center.ApprovalTimedOut += timedOut.Add;
        center.Delivered(Srq("srq-1", "approval", """{"command":"a","request_id":"r1"}"""));
        center.Delivered(Srq("srq-2", "sudo", """{"command":"b"}"""));
        center.Delivered(Srq("srq-3", "clarify", """{"questions":[{"qid":"q0","question":"c"}]}"""));
        center.Receive(new RpcEvent("request.cancel", "rt1", JsonNode.Parse("""{"id":"srq-1","method":"approval","reason":"timeout"}"""), 5));
        Assert.Empty(link.Prompts.Approvals);
        Assert.Equal(["rt1"], timedOut);
        // A resume names only the clarify: the sudo was answered elsewhere.
        center.Authoritative(new OpenRequests("rt1", ["srq-3"], null, "session.resume", 1, null));
        Assert.Empty(link.Prompts.Values);
        Assert.NotNull(link.Prompts.Clarify);
        // Stop's approval.cancelled names queue ids.
        center.Delivered(Srq("srq-4", "approval", """{"command":"d","request_id":"r4"}"""));
        center.Receive(new RpcEvent("approval.cancelled", "rt1", JsonNode.Parse("""{"request_ids":["r4"]}"""), 6));
        Assert.Empty(link.Prompts.Approvals);
    }

    [Fact]
    public async Task AQueueOnlyApprovalIsAnsweredWithApprovalRespond()
    {
        var (center, t, link) = Make();
        center.Authoritative(new OpenRequests("rt1", [], (JsonObject)JsonNode.Parse(
            """{"request_id":"9b1d","command":"git push","choices":["once","deny"]}""")!, "session.resume", 1, null));
        var a = Assert.Single(link.Prompts.Approvals);
        Assert.Equal("queue:9b1d", a.Id);
        Assert.False(a.AllowSession);
        await link.AnswerApprovalAsync(a.Id, ApprovalChoice.Deny);
        var call = t.Calls.First(c => c.Method == "approval.respond");
        Assert.Equal("""{"session_id":"rt1","choice":"deny","all":false,"request_id":"9b1d","profile":"deploys"}""", call.Params.ToJsonString());
        Assert.Empty(t.Frames);
        // The live srq for the same request replaces a restored queue-only copy.
        center.Authoritative(new OpenRequests("rt1", [], (JsonObject)JsonNode.Parse("""{"request_id":"r9","command":"x"}""")!, "session.resume", 1, null));
        center.Delivered(Srq("srq-9", "approval", """{"command":"x","request_id":"r9"}"""));
        Assert.Equal("srq-9", Assert.Single(link.Prompts.Approvals).Id);
    }

    [Fact]
    public async Task ANewSocketDropsWhatNoResumeConfirms()
    {
        var (center, _, link) = Make();
        center.Delivered(Srq("srq-1", "approval", """{"command":"a"}"""));
        center.Delivered(Srq("srq-2", "secret", """{"env_var":"K"}"""));
        center.SocketReady();
        center.Delivered(Srq("srq-2", "secret", """{"env_var":"K"}""", epoch: 2, replayed: true)); // re-delivered: confirmed
        // The unconfirmed one goes once the centre's check has run (a moment; longer on a slow build machine).
        await Until(() => link.Prompts.Approvals.Count == 0);
        Assert.Empty(link.Prompts.Approvals);
        Assert.Single(link.Prompts.Values);
    }

    [Fact]
    public async Task AStoppedTurnsRequestsAreRefused()
    {
        var (center, t, link) = Make();
        link.InterruptedProbe = () => true;
        center.Delivered(Srq("srq-1", "approval", """{"command":"a"}"""));
        center.Delivered(Srq("srq-2", "clarify", """{"questions":[{"qid":"q0","question":"c"}]}"""));
        await Until(() => t.Frames.Count == 2);
        var frames = t.Frames.Select(f => f.ToJsonString()).ToList();
        Assert.Contains("""{"jsonrpc":"2.0","id":"srq-1","error":{"code":-32603,"message":"session interrupted"}}""", frames);
        Assert.Contains("""{"jsonrpc":"2.0","id":"srq-2","result":{}}""", frames);
        Assert.True(link.Prompts.IsEmpty);
    }

    [Fact]
    public async Task ApprovalTimeoutIsReadFromConfig()
    {
        var (center, t, link) = Make();
        t.Config = JsonNode.Parse("""{"approvals":{"timeout":90}}""");
        Assert.Equal(TimeSpan.FromSeconds(90), await link.ApprovalTimeoutAsync(false));
        t.Config = null;
        Assert.Equal(TimeSpan.FromSeconds(90), await link.ApprovalTimeoutAsync(true)); // a failed read keeps the cached value
        Assert.Equal(TimeSpan.FromSeconds(300), await center.ApprovalTimeoutAsync("other", false));
    }

    [Fact]
    public async Task AClarifyToolWithNoQuestionIsUndelivered()
    {
        var (center, t, link) = Make();
        center.Receive(new RpcEvent("tool.start", "rt1", JsonNode.Parse("""{"name":"clarify","tool_id":"c1"}"""), 1));
        await Until(() => link.Prompts.ClarifyUndelivered);
        Assert.Contains(t.Calls, c => c.Method == "session.events.since"
            && c.Params.ToJsonString() == """{"session_id":"rt1","last_seen":2147483647,"profile":"deploys"}""");
    }

    [Fact]
    public void RebindingDropsTheOldRuntimesRequests()
    {
        var (center, _, link) = Make();
        center.Delivered(Srq("srq-1", "approval", """{"command":"a"}"""));
        link.Bind("rt2", "stored1");
        Assert.Empty(link.Prompts.Approvals);
        Assert.Equal(["rt2"], link.SessionIds);
    }
}
