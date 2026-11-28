using System.Text.Json.Nodes;
using Hermes.Core.Activity;
using Hermes.Core.BotPages;
using Hermes.Core.Capabilities;
using Hermes.Core.Chat;
using Hermes.Core.Gateways;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Questions;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests;

public sealed class Hermes0235ParityTests
{
    private sealed class FakePagesGateway(Func<string, string, IEnumerable<KeyValuePair<string, string>>?, JsonNode?, TimeSpan?, string> handler) : IPagesGateway
    {
        public List<(string Method, string Path, TimeSpan? Timeout, JsonNode? Body)> Log { get; } = [];

        public Task<string> RestAsync(string method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            Log.Add((method, path, timeout, body));
            return Task.FromResult(handler(method, path, query, body, timeout));
        }

        public Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default) =>
            Task.FromResult<JsonNode>(new JsonObject());
    }

    private sealed class FakeQuestionTransport : IQuestionTransport
    {
        public bool DeclinesNotShown { get; set; } = true;
        public bool Connected { get; set; } = true;
        public List<(string Method, JsonObject Params)> Calls { get; } = [];
        public List<(string Id, JsonNode Result)> Responses { get; } = [];
        public List<(string Id, int Code, string Message)> Failures { get; } = [];

        public Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout)
        {
            Calls.Add((method, (JsonObject)parameters.DeepClone()));
            if (method == "approval.pending") return Task.FromResult<JsonNode>(new JsonObject { ["approvals"] = new JsonArray() });
            return Task.FromResult<JsonNode>(new JsonObject { ["ok"] = true });
        }

        public Task<int> RespondAsync(string id, JsonNode result)
        {
            Responses.Add((id, result.DeepClone()));
            return Task.FromResult(1);
        }

        public Task<int> FailAsync(string id, int code, string message)
        {
            Failures.Add((id, code, message));
            return Task.FromResult(1);
        }

        public Task<JsonNode?> ConfigAsync(string? profile) => Task.FromResult<JsonNode?>(null);
        public void ReconnectNow() { }
    }

    [Fact]
    public void NewBotCreateTimeoutIs300Seconds()
    {
        Assert.Equal(TimeSpan.FromSeconds(300), NewBotApi.CreateTimeout);
    }

    [Fact]
    public void ClientIdentityAndActivitySerializeAsExpected()
    {
        var id = ClientIdentity.Current();
        Assert.Equal("hermes-hq-windows", id.Name);
        Assert.Equal("desktop", id.Kind);
        var json = id.ToJson();
        Assert.Equal("hermes-hq-windows", json.Str("name"));
        Assert.Equal("desktop", json.Str("kind"));

        var report = new ClientActivityReport(["sess-1"], IdleSeconds: 0, Basis: ClientActivityBasis.Page, CanAlert: true, Away: false).ToJson();
        Assert.Equal("sess-1", report.Arr("sessions")?[0]?.GetValue<string>());
        Assert.Equal(0, report.Num("idle_seconds"));
        Assert.Equal("page", report.Str("basis"));
        Assert.Equal(true, report.Bool("can_alert"));
        Assert.Equal(false, report.Bool("away"));
    }

    [Fact]
    public void CloudWebappStatusValidatesStateAndHttpsUrl()
    {
        var gw = new Uri("https://agent-1.example.com");
        var ready = CloudWebappStatus.From(JsonNode.Parse("""{"webapp_state":"ready","webapp_url":"https://agent-1.example.com/app"}"""), gw);
        Assert.NotNull(ready);
        Assert.Equal(CloudWebappState.Ready, ready!.State);
        Assert.Equal("https://agent-1.example.com/app", ready.WebappUrl?.ToString());

        var nousHost = CloudWebappStatus.From(JsonNode.Parse("""{"webapp_state":"starting","webapp_url":"https://cloud.nousresearch.com/x"}"""), gw);
        Assert.Equal(CloudWebappState.Starting, nousHost!.State);
        Assert.NotNull(nousHost.WebappUrl);

        // Untrusted host or HTTP scheme is dropped.
        var evil = CloudWebappStatus.From(JsonNode.Parse("""{"webapp_state":"not_available","webapp_url":"http://evil.example.org/phish"}"""), gw);
        Assert.Equal(CloudWebappState.NotAvailable, evil!.State);
        Assert.Null(evil.WebappUrl);

        // Unknown webapp_state returns null even if a valid URL is present (matches Swift).
        var unknown = CloudWebappStatus.From(JsonNode.Parse("""{"webapp_state":"migrating","webapp_url":"https://agent-1.example.com/app"}"""), gw);
        Assert.Null(unknown);
    }

    [Fact]
    public async Task SandboxApprovalsValidateRequireFieldsAndCarryDenyReasonAndApprovalReceived()
    {
        var transport = new FakeQuestionTransport();
        using var center = new QuestionCenter(transport, QuestionCenter.Timing.Standard with { Leaving = TimeSpan.FromMilliseconds(5) });

        // Missing path on access approval -> refused with -32602
        center.Delivered(new ServerRequest("srq-bad-access", "approval", new JsonObject { ["kind"] = "access", ["session_id"] = "s1" }, "s1", false, 1));
        await Task.Delay(30);
        Assert.Contains(transport.Failures, f => f.Id == "srq-bad-access" && f.Code == -32602);

        // Missing host on network approval -> refused with -32602
        center.Delivered(new ServerRequest("srq-bad-net", "approval", new JsonObject { ["kind"] = "network", ["session_id"] = "s1" }, "s1", false, 1));
        await Task.Delay(30);
        Assert.Contains(transport.Failures, f => f.Id == "srq-bad-net" && f.Code == -32602);

        // Valid access approval (upstream `access` + `label` fields): allowSession forced false even if choices lists session;
        // ShowsDescription is false on sandbox cards; approval.received fires once; Deny carries reason (capped at 500 chars).
        center.Delivered(new ServerRequest("srq-access-1", "approval", new JsonObject
        {
            ["kind"] = "access",
            ["request_id"] = "req-a1",
            ["session_id"] = "s1",
            ["path"] = "/Users/me/notes",
            ["access"] = "read_write",
            ["label"] = "Notes folder",
            ["risk"] = "Writes inside folder",
            ["choices"] = new JsonArray("once", "session", "always", "deny"),
            ["description"] = "Allow write access to /Users/me/notes",
        }, "s1", false, 1));

        var prompts = center.PromptsFor(["s1"]);
        var prompt = Assert.Single(prompts.Approvals);
        Assert.Equal(ApprovalKind.Access, prompt.Kind);
        Assert.Equal("/Users/me/notes", prompt.Path);
        Assert.Equal(ApprovalAccessLevel.ReadWrite, prompt.AccessLevel);
        Assert.Equal("Notes folder", prompt.Label);
        Assert.False(prompt.AllowSession);
        Assert.False(prompt.ShowsDescription);
        Assert.True(prompt.IsSandbox);

        center.MarkApprovalDisplayed("srq-access-1");
        center.MarkApprovalDisplayed("srq-access-1"); // deduped
        await Task.Delay(30);
        Assert.Single(transport.Calls, c => c.Method == "approval.received" && c.Params.Str("request_id") == "req-a1");

        await center.AnswerApprovalAsync("srq-access-1", ApprovalChoice.Deny, "Not this folder");
        var resp = Assert.Single(transport.Responses, r => r.Id == "srq-access-1");
        Assert.Equal("deny", resp.Result.Str("choice"));
        Assert.Equal("Not this folder", resp.Result.Str("reason"));
    }

    [Fact]
    public void PluginCardAndContentRefusedAndToolOutputRiskWorkEndToEnd()
    {
        var t = new Transcript();
        t.AddLocalUser("blocked request");
        t.Apply(new RpcEvent("message.start", "s1", new JsonObject(), 1));
        t.Apply(new RpcEvent("tool.start", "s1", new JsonObject { ["tool_id"] = "tc-1", ["name"] = "terminal" }, 2));
        t.Apply(new RpcEvent("tool.output_risk", "s1", new JsonObject
        {
            ["tool_id"] = "tc-1",
            ["risk"] = "high",
            ["findings"] = new JsonArray("Possible prompt injection"),
            ["redacted"] = true,
        }, 3));
        var tool = Assert.Single(t.Messages.SelectMany(m => m.Tools));
        Assert.NotNull(tool.OutputRisk);
        Assert.Equal("high", tool.OutputRisk!.Risk);
        Assert.Single(tool.OutputRisk.Findings, "Possible prompt injection");
        Assert.True(tool.OutputRisk.Redacted);
        Assert.Contains("Output redacted (high)", tool.Summary);

        // Live plugin.card dedupes and stays until stored page contains its twin
        t.Apply(new RpcEvent("plugin.card", "s1", new JsonObject
        {
            ["plugin_id"] = "weather",
            ["card_id"] = "c1",
            ["display_text"] = "72°F Sunny",
        }, 4));
        t.Apply(new RpcEvent("plugin.card", "s1", new JsonObject
        {
            ["plugin_id"] = "weather",
            ["card_id"] = "c1",
            ["display_text"] = "72°F Sunny",
        }, 5));
        Assert.Single(t.Messages, m => m.PluginCard != null);

        // History hydration of plugin_card and content_refused (upstream nested display_metadata format)
        var stored = HistoryFold.Fold(
        [
            JsonNode.Parse("""{"id":10,"role":"user","content":"blocked request","display_kind":"content_refused","display_metadata":{"content_refused":{"notice":"Safety policy"}}}"""),
            JsonNode.Parse("""{"id":11,"role":"assistant","display_kind":"plugin_card","display_metadata":{"plugin_card":{"plugin_id":"weather","card_id":"c1"},"display_text":"72°F Sunny"}}"""),
        ]);
        Assert.Equal(2, stored.Count);
        Assert.Equal(Role.System, stored[0].Role);
        Assert.Equal("Safety policy", stored[0].ContentRefusedNotice);
        Assert.Equal("blocked request", stored[0].Text);
        Assert.Equal("weather", stored[1].PluginCard?.PluginId);

        // Replacing with stored page drops BOTH the duplicate live plugin-card-* row AND the optimistic user bubble.
        t.ReplaceWithHistory(stored);
        Assert.Single(t.Messages, m => m.PluginCard != null);
        Assert.DoesNotContain(t.Messages, m => m.Id.StartsWith("local-user-"));
    }

    [Fact]
    public async Task MessagingLiveApplyAndCatalogInstallAndSignatureWork()
    {
        var gw = new FakePagesGateway((method, path, _, _, _) => (method, path) switch
        {
            ("GET", "/api/messaging/platforms") => """
                {"platforms":[{"id":"telegram","name":"Telegram","enabled":true,"configured":true,"gateway_running":true,"state":"connected"}],
                 "available":[{"name":"matrix","title":"Matrix","summary":"Federated chat","badge":"official","disclosure":"Installs matrix plugin","blocked":"","blocked_reason":"","install_command":"hermes plugins install matrix"}],
                 "signature":"sig-abc"}
                """,
            ("GET", "/api/messaging/platforms/signature") => """{"signature":"sig-xyz"}""",
            ("POST", "/api/messaging/catalog/matrix/install") => """{"ok":true,"plugin_name":"matrix","platforms":["matrix"],"warnings":[]}""",
            ("PUT", "/api/messaging/platforms/telegram") => """{"ok":true,"platform":"telegram","hot_served":false,"live":{"applied":false,"state":"not_configured","detail":"Missing token"}}""",
            _ => "{}",
        });
        var api = new MessagingApi(gw);
        var page = await api.PlatformsPageAsync("otto");
        Assert.Single(page.Platforms);
        var cat = Assert.Single(page.Available);
        Assert.Equal("Official", cat.BadgeWord);
        Assert.Equal("sig-abc", page.Signature);
        Assert.Equal("sig-xyz", await api.SignatureAsync("otto"));

        var installed = await api.InstallCatalogAsync("matrix", "otto");
        Assert.True(installed.Ok);
        Assert.Equal(["matrix"], installed.RegisteredPlatforms);
        Assert.Contains(gw.Log, x => x.Path == "/api/messaging/catalog/matrix/install" && x.Timeout == TimeSpan.FromSeconds(300));

        // live.state == "not_configured" must NOT raise restart banner.
        var update = await api.UpdateWithLiveAsync("telegram", MessagingBodies.Enabled(true), "otto");
        Assert.True(update.NeedsCredentials);
        Assert.False(update.RequiresRestart);
        Assert.Equal("Missing token", update.RestartDetail);
    }

    [Fact]
    public void SkillInfoDecodesLockedFlag()
    {
        var s = SkillInfo.Read(JsonNode.Parse("""{"name":"deploy","description":"Ship builds","enabled":true,"locked":true}"""));
        Assert.NotNull(s);
        Assert.True(s!.Locked);
    }

    [Fact]
    public async Task TeammateWaitsAndHostedGroupsControlsWork()
    {
        // bot_delivery.list
        var waitRes = await TeammateWaitsApi.ListAsync((method, p, _, _) =>
        {
            Assert.Equal("bot_delivery.list", method);
            Assert.Equal("otto", p.Str("profile"));
            return Task.FromResult(JsonNode.Parse("""
                {"sender":"otto","deliveries":[
                  {"delivery_id":"d1","target":"ivy","target_handle":"ivy","state":"waiting_on_you","since":1700000000,"preview":"Check PR","waiting_on":"clarify"},
                  {"delivery_id":"d2","target":"wren","target_handle":"wren","state":"failed","since":1700000000,"preview":"Deploy","reason":"unknown_outcome"}
                ]}
                """)!);
        }, "otto");
        Assert.False(waitRes.Unsupported);
        Assert.Equal(2, waitRes.Rows.Count);
        Assert.Equal("Waiting on you — answer question", waitRes.Rows[0].StatusLine);
        Assert.True(waitRes.Rows[1].IsUnknownOutcome);
        Assert.Single(BotDeliveryRow.Visible(waitRes.Rows, new HashSet<string> { "d2" }));

        // Unsupported (-32601)
        var old = await TeammateWaitsApi.ListAsync((_, _, _, _) =>
            throw new GatewayException("rpc", "method not found", rpcCode: -32601), "otto");
        Assert.True(old.Unsupported);

        // Hosted groups: approve, continue, context, per-profile approval mode, groups.changed deduper
        var calls = new List<(string Method, JsonObject Params)>();
        var hosted = new HostedRoomsApi((m, p, _, _) =>
        {
            calls.Add((m, (JsonObject)p.DeepClone()));
            if (m == "groups.context")
                return Task.FromResult<JsonNode>(new JsonObject { ["context"] = new JsonObject { ["purpose"] = p.Str("purpose"), ["notes"] = p.Str("notes"), ["routing"] = "lead", ["lead_member_id"] = "ivy" } });
            if (m is "config.get" or "config.set")
                return Task.FromResult<JsonNode>(new JsonObject { ["value"] = p.Str("value") ?? "smart" });
            return Task.FromResult<JsonNode>(new JsonObject { ["ok"] = true });
        });

        var pending = HostedPendingAction.From(JsonNode.Parse("""
            {"kind":"approval","member_id":"ivy","task_id":"t1","execution_generation":2,"request_id":"req-9",
             "approval":{"command":"ls -la","choices":["once","deny"]}}
            """))!;
        Assert.True(pending.IsReviewableApproval);
        await hosted.ApproveAsync("default", "room-1", pending, ApprovalChoice.Once);
        Assert.Contains(calls, c => c.Method == "groups.approve" && c.Params.Str("request_id") == "req-9" && c.Params.Str("choice") == "once");

        await hosted.ContinueDiscussionAsync("default", "room-1", "evt-1");
        Assert.Contains(calls, c => c.Method == "groups.continue" && c.Params.Str("discussion_event_id") == "evt-1");

        var savedCtx = await hosted.SetContextAsync("default", "room-1", "Release triage", "Check logs", "lead", "ivy");
        Assert.Equal("Release triage", savedCtx.Purpose);
        Assert.Equal("lead", savedCtx.Routing);
        Assert.Equal("ivy", savedCtx.LeadMemberId);

        Assert.Equal("smart", await hosted.GetApprovalModeAsync("ivy"));
        Assert.Equal("manual", await hosted.SetApprovalModeAsync("ivy", "manual"));
        Assert.Contains(calls, c => c.Method == "config.set" && c.Params.Str("profile") == "ivy" && c.Params.Str("key") == "approvals.mode" && c.Params.Str("value") == "manual");

        var deduper = new GroupsChangedDeduper();
        var ev = GroupsChangedPayload.From(JsonNode.Parse("""{"room_ids":["room-1"],"broadcast_id":"b-42"}"""));
        Assert.True(deduper.ShouldHandle(ev));
        Assert.False(deduper.ShouldHandle(ev));
    }
}
