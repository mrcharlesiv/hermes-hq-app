using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Activity;
using Hermes.Core.Auth;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests;

/// Wave 4C parity tests: BackgroundProcess (ANSI/\r cleanup, preview lines, elapsed, freshness, chips),
/// BackgroundJobWords (agent detection, `# comment`, transcript `terminal` matching, unclipped FullHeadline),
/// BackgroundProcessesApi (`process.list` -32601 suppression, `process.kill`, `subagent.roster`, `agents.list`,
/// `subagent.tail`, `sessions/working` & `serve/working`), ActivityStore.ProcessClaim + StaleWork reconciliation,
/// WorkingLedgerWatch, and HelperReport / HelperTailReport.
public sealed class BackgroundWorkersParityTests
{
    private static JsonNode N(string json) => JsonNode.Parse(json)!;

    // ------------------------------------------------------------------ 1. BackgroundProcess

    [Fact]
    public void BackgroundProcess_CleansAnsiAndCarriageReturns_PreviewLines_Duration_And_Freshness()
    {
        const string dirty = "\n\x1b[32m[05:24]\x1b[0m Checking build 42\r\nDownloading 10%\rDownloading 100%\n\x1b[1mWaiting on review\x1b[0m\n\n";
        Assert.Equal("[05:24] Checking build 42\nDownloading 100%\nWaiting on review", BackgroundProcess.CleanTail(dirty));

        var proc = new BackgroundProcess("p_tail", "make", "running", UptimeSeconds: 372, OutputTail: dirty);
        Assert.Equal("[05:24] Checking build 42\nDownloading 100%\nWaiting on review", proc.CleanOutput);
        Assert.Equal("Waiting on review", proc.LastLine);
        Assert.Equal(["[05:24] Checking build 42", "Downloading 100%"], proc.EarlierPreviewLines);
        Assert.Equal("Downloading 100%\nWaiting on review", proc.TailLines);
        Assert.Equal("Background task · 6m", proc.ChipWords);
        Assert.Equal("Running · 6m", proc.Detail);

        // Long output lines cap at 160 chars with ellipsis.
        var longLine = proc with { OutputTail = new string('x', 400) };
        Assert.Equal(160, longLine.LastLine.Length);
        Assert.EndsWith("…", longLine.LastLine);

        // Chip words for 0, 1 (known & unknown uptime), and multiple running jobs.
        Assert.Null(BackgroundProcess.FormatChipWords([]));
        Assert.Equal("Background task · 6m", BackgroundProcess.FormatChipWords([proc]));
        var noTime = proc with { UptimeSeconds = null };
        Assert.Equal("Background task", noTime.ChipWords);
        Assert.Equal("Background task", BackgroundProcess.FormatChipWords([noTime]));
        Assert.Equal("2 background tasks", BackgroundProcess.FormatChipWords([proc, noTime]));

        // Exited detail & duration formatting.
        var exited = new BackgroundProcess("p2", "", "exited", UptimeSeconds: 4000, ExitCode: 1);
        Assert.False(exited.IsRunning);
        Assert.Equal("Background command", exited.Title);
        Assert.Equal("Exited (code 1)", exited.Detail);
        Assert.Equal("42s", BackgroundProcess.FormatDuration(42));
        Assert.Equal("1h", BackgroundProcess.FormatDuration(3600));
        Assert.Equal("1h 2m", BackgroundProcess.FormatDuration(3720));

        // Live elapsed seconds (from uptime + observedAt, and fallback to StartedAt) + FreshnessWords.
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1_000);
        var rich = new BackgroundProcess(
            "p_rich", "make", "running",
            UptimeSeconds: 300,
            StartedAt: DateTimeOffset.FromUnixTimeSeconds(700),
            LastOutputAt: t0);
        Assert.Equal(345, rich.ElapsedSeconds(t0, t0.AddSeconds(45)));
        Assert.Equal(345, rich.ElapsedSeconds(1_000, 1_045));
        Assert.Equal("Updated just now", rich.FreshnessWords(t0.AddSeconds(3)));
        Assert.Equal("Updated 1m ago", rich.FreshnessWords(t0.AddSeconds(75)));
        Assert.Equal("", (rich with { LastOutputAt = null }).FreshnessWords(t0.AddSeconds(10)));

        var fromStartedOnly = rich with { UptimeSeconds = null };
        Assert.Equal(350, fromStartedOnly.ElapsedSeconds(null, t0.AddSeconds(50)));
    }

    [Fact]
    public void BackgroundProcess_ParseList_DecodesRichFieldsAndTimestampsLeniently()
    {
        var answer = N("""
        {
          "processes": [
            {
              "session_id": "proc_rich",
              "command": "python3 - <<'PY'\nprint('hi')\nPY",
              "cwd": "/Users/me/Projects/release-job",
              "pid": 4211,
              "status": "running",
              "uptime_seconds": 300,
              "started_at": "2026-10-13T02:14:26Z",
              "last_output_at": "2026-10-13T02:19:10Z",
              "watch_patterns": ["READY_FOR_SALE", "FAILED"],
              "watch_hit": "READY_FOR_SALE",
              "output_tail": "line 1\nline 2\nline 3\n"
            },
            {
              "id": "proc_exited",
              "command": "npm test",
              "status": "exited",
              "exit_code": 2,
              "output_preview": "FAIL a.test.js"
            },
            {
              "command": "missing id is skipped"
            }
          ]
        }
        """);

        var list = BackgroundProcess.ParseList(answer);
        Assert.Equal(["proc_rich", "proc_exited"], list.Select(p => p.Id));
        var rich = list[0];
        Assert.Equal(4211, rich.Pid);
        Assert.Equal("/Users/me/Projects/release-job", rich.Cwd);
        Assert.NotNull(rich.StartedAt);
        Assert.NotNull(rich.LastOutputAt);
        Assert.Equal(["READY_FOR_SALE", "FAILED"], rich.WatchPatterns);
        Assert.Equal("READY_FOR_SALE", rich.WatchHit);
        Assert.Equal("line 3", rich.LastLine);
        Assert.Equal(["line 1", "line 2"], rich.EarlierPreviewLines);
        Assert.NotNull(BackgroundProcess.ParseTimestamp(JsonValue.Create("2026-10-13T02:14:26")));
        Assert.NotNull(BackgroundProcess.ParseTimestamp(JsonValue.Create(1700000000.5)));
        Assert.Equal("FAIL a.test.js", list[1].LastLine);
        Assert.Equal(2, list[1].ExitCode);
        Assert.Empty(BackgroundProcess.ParseList(null));
    }

    // ------------------------------------------------------------------ 2. BackgroundJobWords & BackgroundTaskText

    [Fact]
    public void BackgroundJobWords_DetectsAllFiveAgents_Comment_Program_Folder_And_QuietLines()
    {
        // All 5 coding agents with valued-flag skipping.
        Assert.Equal(new BackgroundJobWords.AgentInfo("Claude Code", "Fix the auth flow"),
            BackgroundJobWords.Agent("claude -p --permission-mode acceptEdits 'Fix the auth flow. Never commit.'"));
        Assert.Equal(new BackgroundJobWords.AgentInfo("Codex", "Tidy the docs"),
            BackgroundJobWords.Agent("codex exec -m gpt-5 'Tidy the docs'"));
        Assert.Equal(new BackgroundJobWords.AgentInfo("Gemini CLI", "Audit logs"),
            BackgroundJobWords.Agent("/usr/local/bin/gemini --prompt \"Audit logs\""));
        Assert.Equal(new BackgroundJobWords.AgentInfo("OpenCode", "Refactor parser"),
            BackgroundJobWords.Agent("opencode run 'Refactor parser'"));
        Assert.Equal(new BackgroundJobWords.AgentInfo("Cursor Agent", "Run tests"),
            BackgroundJobWords.Agent("cursor-agent --print 'Run tests'"));
        Assert.Null(BackgroundJobWords.Agent("claude --version"));

        // Leading # comment wins; #! shebang is not treated as a comment title.
        var named = new BackgroundProcess("p1", "# Archiving Mac build 42\ncd ~/x/ship-42-mac && python3 scripts/ship.py archive > /tmp/archive.log 2>&1", "running", 60);
        Assert.Equal("Archiving Mac build 42", named.Headline);
        Assert.Equal("python3 scripts/ship.py archive · ship-42-mac", named.DetailLine);
        Assert.Equal("Writing to archive.log", named.StatusLine);
        Assert.Null(BackgroundTaskText.Comment("#!/bin/bash\nmake build"));

        // Friendly inline script labels vs named scripts.
        Assert.Equal("Python script", BackgroundJobWords.FriendlyProgram("python3 -"));
        Assert.Equal("Python script", BackgroundJobWords.FriendlyProgram("python3 -u -"));
        Assert.Equal("Shell script", BackgroundJobWords.FriendlyProgram("bash -c 'sleep 5'"));
        Assert.Equal("Node script", BackgroundJobWords.FriendlyProgram("node -e 'setInterval(()=>{},1000)'"));
        Assert.Equal("Bun script", BackgroundJobWords.FriendlyProgram("bun --eval 'console.log(1)'"));
        Assert.Equal("python3 scripts/ship.py archive", BackgroundJobWords.FriendlyProgram("python3 scripts/ship.py archive"));

        var heredoc = new BackgroundProcess("p_py", "# Shipping beta build\ncd ~/Projects/app-wt/release-job && python3 - <<'PY'\nprint('ok')\nPY", "running", 120);
        Assert.Equal("Shipping beta build", heredoc.Headline);
        Assert.Equal("Python script · release-job", heredoc.DetailLine);

        // Quiet lines: agent, redirect file, /dev/null, tee, long quiet duration, fresh quiet.
        var agentJob = new BackgroundProcess("pa", "cd ~/wt/goals-2 && claude -p 'Read .brief.md and finish it. Never commit.' --max-turns 200", "running", 4920);
        Assert.Equal("Read .brief.md and finish it", agentJob.Headline);
        Assert.Equal("Claude Code · goals-2", agentJob.DetailLine);
        Assert.Equal("Quiet until it's done", agentJob.StatusLine);

        var quietWatch = new BackgroundProcess("pw", "npm run watch", "running", 4920, Cwd: "/Users/me/site");
        Assert.Equal("npm run watch", quietWatch.Headline);
        Assert.Equal("site", quietWatch.DetailLine);
        Assert.Equal("No output for 1h 22m", quietWatch.StatusLine);
        Assert.Equal("No output yet", new BackgroundProcess("p3", "npm run watch", "running", 20).StatusLine);
        Assert.Equal("No output yet", BackgroundTaskText.QuietLine("xcrun simctl list > /dev/null"));
        Assert.Equal("No output yet", BackgroundTaskText.QuietLine("npm test 2>&1 | tee test.log"));
        Assert.Equal("Writing to build.log", BackgroundTaskText.QuietLine("make >> build.log"));
        Assert.Equal("The app's own test gate", BackgroundJobWords.WithoutLeadIn("Now the app's own test gate"));
        Assert.Equal("Running it", BackgroundJobWords.WithoutLeadIn("Running it"));
    }

    [Fact]
    public void BackgroundJobWords_TranscriptMatching_RecoversFullCommand_BotNote_And_UnclippedFullHeadline()
    {
        var longCmd = "cd ~/Projects/release && python3 - <<'PY'\n" + string.Concat(Enumerable.Repeat("x = 1\n", 50)) + "PY";
        var clipped = longCmd[..200];
        var argsJson = new JsonObject { ["command"] = longCmd, ["background"] = true }.ToJsonString();

        var messages = new List<ChatMessage>
        {
            new("a1", Role.Assistant,
            [
                new TextPart("Build 41 is still waiting for review, so the script will poll every five minutes and submit build 42 once it clears. Starting the release watcher now."),
                new ToolPart(new ToolCall("t1", "terminal", "terminal", null, ToolState.Done, ArgsJson: argsJson)),
            ]),
        };

        var matched = BackgroundJobWords.Match(clipped, messages);
        Assert.NotNull(matched);
        Assert.Equal("The release watcher now", matched!.BotWords);
        Assert.Equal("The release watcher now", matched.FullBotWords);
        Assert.Contains("poll every five minutes", matched.BotNote);
        Assert.Equal(longCmd, matched.FullCommand);

        // Long bot sentence (>90 chars) and long agent prompt (>80 chars): Headline clips, FullHeadline stays unclipped (ba08fcdd4).
        const string longSentence = "Restarting the landing job without the wait (full unit tests on a clean sim, UI video test, Mac build, then advancing main)";
        var longMsgs = new List<ChatMessage>
        {
            new("a2", Role.Assistant,
            [
                new TextPart(longSentence + "."),
                new ToolPart(new ToolCall("t2", "terminal", """{"command":"make land"}""", null, ToolState.Done)),
            ]),
        };
        var longJob = new BackgroundProcess("p_long", "make land", "running", 40).WithTranscriptMatch(longMsgs);
        Assert.EndsWith("…", longJob.Headline);
        Assert.True(longJob.Headline.Length <= 90);
        Assert.Equal(longSentence, longJob.FullHeadline);
        Assert.Null(longJob.BotNote);

        const string longPrompt = "Read the brief in this folder, run every verification check on a clean simulator, and write the full summary report";
        var longAgent = new BackgroundProcess("p_ag", $"claude -p '{longPrompt}'", "running", 30);
        Assert.EndsWith("…", longAgent.Headline);
        Assert.True(longAgent.Headline.Length <= 80);
        Assert.Equal(longPrompt, longAgent.FullHeadline);
    }

    // ------------------------------------------------------------------ 3. BackgroundProcessesApi (RPC & REST)

    private sealed class LoopbackWorkerGateway : IAsyncDisposable
    {
        private readonly HttpListener _http = new();
        private readonly CancellationTokenSource _life = new();
        private readonly List<(string Method, JsonObject Params)> _rpcLog = [];
        private readonly List<string> _restLog = [];

        public string Url { get; }
        public Func<string, JsonObject, (JsonNode? Result, int? ErrorCode, string? ErrorMessage)>? OnRpc { get; set; }
        public Func<string, (int Status, JsonNode? Body)>? OnRest { get; set; }

        public LoopbackWorkerGateway()
        {
            var probe = new TcpListener(IPAddress.Loopback, 0);
            probe.Start();
            var port = ((IPEndPoint)probe.LocalEndpoint).Port;
            probe.Stop();
            Url = $"http://127.0.0.1:{port}";
            _http.Prefixes.Add(Url + "/");
            _http.Start();
            _ = Task.Run(ServeAsync);
        }

        public IReadOnlyList<(string Method, JsonObject Params)> RpcLog { get { lock (_rpcLog) return [.. _rpcLog]; } }
        public IReadOnlyList<string> RestLog { get { lock (_restLog) return [.. _restLog]; } }

        private async Task ServeAsync()
        {
            while (!_life.IsCancellationRequested)
            {
                HttpListenerContext ctx;
                try { ctx = await _http.GetContextAsync(); } catch { return; }
                _ = Task.Run(() => HandleAsync(ctx));
            }
        }

        private async Task HandleAsync(HttpListenerContext ctx)
        {
            var path = ctx.Request.Url!.AbsolutePath;
            if (path == "/api/auth/ws-ticket")
            {
                await WriteJsonAsync(ctx.Response, 200, """{"ticket":"synthetic-ticket"}""");
                return;
            }
            if (path == "/api/ws" && ctx.Request.IsWebSocketRequest)
            {
                var ws = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
                await SendAsync(ws, new JsonObject
                {
                    ["jsonrpc"] = "2.0", ["method"] = "event",
                    ["params"] = new JsonObject { ["type"] = "gateway.ready", ["payload"] = new JsonObject { ["replay_epoch"] = "e1" } },
                });
                var buffer = new byte[64 * 1024];
                while (ws.State == WebSocketState.Open && !_life.IsCancellationRequested)
                {
                    using var frame = new MemoryStream();
                    try
                    {
                        WebSocketReceiveResult r;
                        do
                        {
                            r = await ws.ReceiveAsync(buffer, _life.Token);
                            if (r.MessageType == WebSocketMessageType.Close) return;
                            frame.Write(buffer, 0, r.Count);
                        } while (!r.EndOfMessage);
                    }
                    catch { return; }

                    if (JsonNode.Parse(Encoding.UTF8.GetString(frame.ToArray())) is not JsonObject req) continue;
                    var method = req["method"]?.GetValue<string>() ?? "";
                    var p = req["params"] as JsonObject ?? new JsonObject();
                    if (method != "client.capabilities") lock (_rpcLog) _rpcLog.Add((method, (JsonObject)p.DeepClone()));
                    if (req["id"] is not { } id) continue;

                    if (method == "client.capabilities")
                    {
                        await SendAsync(ws, new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id.DeepClone(), ["result"] = new JsonObject() });
                        continue;
                    }

                    var (result, errCode, errMsg) = OnRpc?.Invoke(method, p) ?? (new JsonObject(), null, null);
                    if (errCode is { } code)
                    {
                        await SendAsync(ws, new JsonObject
                        {
                            ["jsonrpc"] = "2.0", ["id"] = id.DeepClone(),
                            ["error"] = new JsonObject { ["code"] = code, ["message"] = errMsg ?? "error" },
                        });
                    }
                    else
                    {
                        await SendAsync(ws, new JsonObject
                        {
                            ["jsonrpc"] = "2.0", ["id"] = id.DeepClone(),
                            ["result"] = result ?? new JsonObject(),
                        });
                    }
                }
                return;
            }

            lock (_restLog) _restLog.Add(path);
            var (status, body) = OnRest?.Invoke(path) ?? (404, new JsonObject { ["error"] = "not found" });
            await WriteJsonAsync(ctx.Response, status, (body ?? new JsonObject()).ToJsonString());
        }

        private static async Task WriteJsonAsync(HttpListenerResponse res, int status, string json)
        {
            var bytes = Encoding.UTF8.GetBytes(json);
            res.StatusCode = status;
            res.ContentType = "application/json";
            res.ContentLength64 = bytes.Length;
            await res.OutputStream.WriteAsync(bytes);
            res.Close();
        }

        private static Task SendAsync(WebSocket ws, JsonNode node) =>
            ws.SendAsync(Encoding.UTF8.GetBytes(node.ToJsonString()), WebSocketMessageType.Text, true, CancellationToken.None);

        public ValueTask DisposeAsync()
        {
            _life.Cancel();
            try { _http.Close(); } catch (ObjectDisposedException) { }
            return ValueTask.CompletedTask;
        }
    }

    [Fact]
    public async Task BackgroundProcessesApi_CoversAllRpcs_32601Suppression_And_WorkingLedgerRoutes()
    {
        await using var gw = new LoopbackWorkerGateway();
        var unsupported = false;
        gw.OnRpc = (method, p) =>
        {
            if (unsupported) return (null, -32601, $"method not found: {method}");
            return method switch
            {
                "process.list" => (N("""{"processes":[{"session_id":"p1","command":"npm test","status":"running","uptime_seconds":90,"output_tail":"\u001b[32mPASS\u001b[0m"},{"session_id":"p2","command":"done","status":"exited","exit_code":0}]}"""), null, null),
                "process.kill" => (N("""{"status":"killed","session_id":"p1"}"""), null, null),
                "subagent.roster" => (N("""{"sessions":[{"session_id":"s1","subagents":1,"background":2}]}"""), null, null),
                "agents.list" => (N("""{"processes":[{"session_id":"p1","status":"running"}]}"""), null, null),
                "subagent.tail" => (N("""{"available":true,"text":"\u001b[1mstep output\u001b[0m\n","truncated":true,"files_written":["src/a.cs"],"files_read":["README.md"],"steps":[{"tool_name":"read_file","tool_preview":"README.md"}]}"""), null, null),
                _ => (new JsonObject(), null, null),
            };
        };
        gw.OnRest = path => path switch
        {
            WorkingLedgerWatch.LedgerPath => (200, N("""{"sessions":[{"id":"s_gw","profile":"scout","status":"working"}]}""")),
            WorkingLedgerWatch.ServePath => (200, N("""{"sessions":[{"id":"s_serve","profile":"default","status":"working"}]}""")),
            _ => (404, new JsonObject()),
        };

        var account = new StoredAccount(gw.Url, "tester");
        await using var client = new HermesClient(new GatewaySession(GatewayAddress.Validated(gw.Url), account, new MemoryTokenStore()));
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token);

        // process.list
        var procs = await BackgroundProcessesApi.ListProcessesAsync(client, "rt_1", "scout");
        Assert.NotNull(procs);
        Assert.Equal(["p1", "p2"], procs!.Select(p => p.Id));
        Assert.Equal("PASS", procs![0].CleanOutput);
        Assert.True(JsonNode.DeepEquals(N("""{"session_id":"rt_1","profile":"scout"}"""), gw.RpcLog.Last(x => x.Method == "process.list").Params));

        // process.kill
        Assert.True(await BackgroundProcessesApi.KillProcessAsync(client, "rt_1", "p1", "scout"));
        Assert.True(JsonNode.DeepEquals(N("""{"session_id":"rt_1","profile":"scout","process_id":"p1"}"""), gw.RpcLog.Last(x => x.Method == "process.kill").Params));

        // subagent.roster & agents.list strict profile params ({} for default, {profile} for named bot)
        var roster = await BackgroundProcessesApi.ReadSubagentRosterAsync(client, "default");
        Assert.NotNull(roster);
        Assert.Empty(gw.RpcLog.Last(x => x.Method == "subagent.roster").Params);
        var agents = await BackgroundProcessesApi.ReadAgentsListAsync(client, "scout");
        Assert.NotNull(agents);
        Assert.True(JsonNode.DeepEquals(N("""{"profile":"scout"}"""), gw.RpcLog.Last(x => x.Method == "agents.list").Params));

        // subagent.tail
        var tail = await BackgroundProcessesApi.ReadSubagentTailAsync(client, "rt_1", "sa_9", "scout");
        Assert.NotNull(tail);
        Assert.True(tail!.Available);
        Assert.True(tail.Truncated);
        Assert.Equal("step output", tail.Output);
        Assert.Single(tail.Steps);
        Assert.Equal("Read File(\"README.md\")", tail.Steps[0].Text);
        Assert.Equal(2, tail.Files.Count);

        // sessions/working & serve/working
        var ledger = await BackgroundProcessesApi.ReadWorkingLedgerAsync(client, serve: false);
        Assert.NotNull(ledger);
        Assert.False(ledger!.FromServe);
        Assert.Contains("s_gw", ledger.SessionIds);
        Assert.Contains("s_gw", ledger.SessionIdsForProfile("scout"));

        var serve = await BackgroundProcessesApi.ReadWorkingLedgerAsync(client, serve: true);
        Assert.NotNull(serve);
        Assert.True(serve!.FromServe);
        Assert.Contains("s_serve", serve.SessionIds);

        // -32601 suppression across all RPCs + 503/404 suppression on working ledger
        unsupported = true;
        Assert.Null(await BackgroundProcessesApi.ListProcessesAsync(client, "rt_1", "scout"));
        Assert.False(await BackgroundProcessesApi.KillProcessAsync(client, "rt_1", "p1", "scout"));
        Assert.Null(await BackgroundProcessesApi.ReadSubagentRosterAsync(client, "scout"));
        Assert.Null(await BackgroundProcessesApi.ReadAgentsListAsync(client, "scout"));
        Assert.Null(await BackgroundProcessesApi.ReadSubagentTailAsync(client, "rt_1", "sa_9", "scout"));

        gw.OnRest = _ => (503, new JsonObject());
        Assert.Null(await BackgroundProcessesApi.ReadWorkingLedgerAsync(client, serve: true));
    }

    // ------------------------------------------------------------------ 4. ActivityStore.ProcessClaim & StaleWork

    [Fact]
    public async Task ActivityStore_ProcessClaim_And_StaleWorkReconciliation_WithRosterFallback()
    {
        var store = new ActivityStore("default", "rt_1", "st_1");
        var changedEvents = new List<string>();
        store.ProcessClaimsChanged += rid => changedEvents.Add(rid);

        Assert.False(store.HasLiveWork);
        Assert.True(store.SetProcessClaims("rt_1", "default", "st_1",
        [
            new ActivityStore.ProcessClaim("proc_live", Running: true),
            new ActivityStore.ProcessClaim("proc_done", Running: false),
        ]));
        Assert.True(store.HasRunningProcessClaims);
        Assert.True(store.HasLiveWork);
        Assert.True(store.HasLiveWorkForProfile("default"));
        Assert.True(store.HasLiveWorkForStoredId("st_1"));
        Assert.Contains("st_1", store.LiveWorkStoredIds("default"));
        Assert.Single(changedEvents);

        // StaleWork pure helpers
        var activeSet = StaleWork.RunningProcesses(N("""{"processes":[{"session_id":"proc_other","status":"running"},{"session_id":"proc_live","status":"exited"}]}"""))!;
        var kept = StaleWork.DropProcesses(store.GetProcessClaims("rt_1"), activeSet)!;
        Assert.Single(kept);
        Assert.Equal("proc_done", kept[0].Id); // finished claim kept; missing running claim dropped

        // Fallback path: agents.list returns -32601 -> asks subagent.roster, skips visibleRuntimeId, drops offscreen chat.
        store.SetProcessClaims("rt_2", "default", "st_2", [new ActivityStore.ProcessClaim("proc_bg", Running: true)]);
        var rpcCalls = new List<(string Method, JsonObject Params)>();
        Task<JsonNode> Call(string method, JsonObject p, CancellationToken _)
        {
            rpcCalls.Add((method, (JsonObject)p.DeepClone()));
            if (method == "agents.list")
                throw new GatewayException("rpc", "unknown method: agents.list", rpcCode: -32601);
            if (method == "subagent.roster")
                return Task.FromResult<JsonNode>(N("""{"sessions":[{"session_id":"st_other","background":1}]}"""));
            return Task.FromResult<JsonNode>(new JsonObject());
        }

        // rt_1 is visible -> kept; rt_2 is offscreen and absent from roster -> dropped.
        Assert.True(await store.ReconcileStaleProcessesAsync(Call, visibleRuntimeId: "rt_1"));
        Assert.True(store.AgentsListUnsupported);
        Assert.Equal(1, store.AgentsListReads);
        Assert.Equal(1, store.RosterReads);
        Assert.Empty(rpcCalls.Single(c => c.Method == "subagent.roster").Params); // default profile asks with {}
        Assert.Equal(2, store.GetProcessClaims("rt_1").Count);
        Assert.Empty(store.GetProcessClaims("rt_2"));

        // Subsequent stale check remembers agents.list -32601 and does not call it again.
        await store.ReconcileStaleProcessesAsync(Call, visibleRuntimeId: "rt_1");
        Assert.Equal(1, store.AgentsListReads);

        // gateway.ready resets unsupported flags.
        store.Apply(new RpcEvent("gateway.ready", "", null, null));
        Assert.False(store.AgentsListUnsupported);
        Assert.False(store.RosterUnsupported);
    }

    // ------------------------------------------------------------------ 5. WorkingLedgerWatch

    [Fact]
    public async Task WorkingLedgerWatch_UnionsRoutes_HandlesMissingRoutes_TurnEnded_And_Roster()
    {
        var ledgerIds = new List<string> { "gw_1" };
        var serveIds = new List<string> { "serve_1" };
        int? ledgerStatus = null;
        int? serveStatus = null;
        var rosterMode = 0;
        var restCalls = new List<string>();
        var rpcCalls = new List<(string Method, JsonObject Params)>();

        Task<JsonNode> RestGet(string path, CancellationToken _)
        {
            restCalls.Add(path);
            (List<string> ids, int? status) = path == WorkingLedgerWatch.LedgerPath ? (ledgerIds, ledgerStatus)
                : path == WorkingLedgerWatch.ServePath ? (serveIds, serveStatus) : (new List<string>(), (int?)404);
            if (status is { } code) throw new GatewayException("http", $"HTTP {code}", code);
            var arr = new JsonArray();
            foreach (var id in ids) arr.Add(new JsonObject { ["id"] = id, ["profile"] = "default" });
            return Task.FromResult<JsonNode>(new JsonObject { ["sessions"] = arr });
        }

        Task<JsonNode> RpcCall(string method, JsonObject p, CancellationToken _)
        {
            rpcCalls.Add((method, (JsonObject)p.DeepClone()));
            if (method != "subagent.roster") return Task.FromResult<JsonNode>(new JsonObject());
            if (rosterMode == 1) throw new GatewayException("timeout", "timed out");
            if (rosterMode == 2) throw new GatewayException("rpc", "unknown method", rpcCode: -32601);
            return Task.FromResult<JsonNode>(p.Text("profile") == "hermes-hq"
                ? N("""{"sessions":[{"session_id":"desk","subagents":0,"background":2},{"session_id":"idle","subagents":0,"background":0}]}""")
                : N("""{"sessions":[{"session_id":"kid","subagents":1,"background":0}]}"""));
        }

        var clock = DateTimeOffset.FromUnixTimeSeconds(1_000);
        using var watch = new WorkingLedgerWatch(RestGet, RpcCall)
        {
            Now = () => clock,
            Profiles = () => ["hermes-hq", "default", ""],
        };

        await watch.ReadOnceAsync();
        Assert.Equal(["gw_1", "serve_1"], watch.StoredIds.Order());
        Assert.Equal(["desk", "kid"], watch.BackgroundIds.Order());
        Assert.Equal(2, rpcCalls.Count); // default & "" deduped into one {} call + hermes-hq
        Assert.Contains(rpcCalls, c => c.Params.Count == 0);
        Assert.Contains("desk", watch.WorkingIdsForProfile("hermes-hq"));

        // TurnEnded removes active turn immediately and outranks reads started before it, leaving BackgroundIds intact.
        clock = clock.AddSeconds(2);
        watch.TurnEnded("serve_1");
        watch.TurnEnded("desk");
        Assert.DoesNotContain("serve_1", watch.StoredIds);
        Assert.Contains("desk", watch.BackgroundIds);

        clock = clock.AddSeconds(-1); // read started before TurnEnded
        await watch.ReadOnceAsync();
        Assert.DoesNotContain("serve_1", watch.StoredIds);

        clock = clock.AddSeconds(5); // read started after TurnEnded
        await watch.ReadOnceAsync();
        Assert.Contains("serve_1", watch.StoredIds);

        // 404 on serve/working is remembered and skipped; 500 on ledger keeps last known word.
        serveStatus = 404;
        await watch.ReadOnceAsync();
        Assert.Equal(["gw_1"], watch.StoredIds.Order());
        var serveBefore = restCalls.Count(p => p == WorkingLedgerWatch.ServePath);
        ledgerStatus = 500;
        await watch.ReadOnceAsync();
        Assert.Equal(serveBefore, restCalls.Count(p => p == WorkingLedgerWatch.ServePath));
        Assert.Equal(["gw_1"], watch.StoredIds.Order());

        // Roster transient error keeps last word; -32601 clears & suppresses re-asking.
        rosterMode = 1;
        await watch.ReadOnceAsync();
        Assert.Equal(["desk", "kid"], watch.BackgroundIds.Order());
        rosterMode = 2;
        await watch.ReadOnceAsync();
        Assert.Empty(watch.BackgroundIds);
        var rosterCount = rpcCalls.Count;
        await watch.ReadOnceAsync();
        Assert.Equal(rosterCount, rpcCalls.Count);

        watch.Stop();
        Assert.Empty(watch.StoredIds);
        Assert.Empty(watch.BackgroundIds);
    }

    // ------------------------------------------------------------------ 6. HelperReport & HelperTailReport

    [Fact]
    public void HelperReport_ParsesSingleAndBatchEnvelopes_SummarizesStatuses_And_CombinesTail()
    {
        const string batch = """
            [ASYNC DELEGATION BATCH — deleg_abc123]
            --- ✓ TASK 1/2: Audit tests  (status=completed, api_calls=12, 42.1s) ---
            --- ✗ TASK 2/2: Build release  (status=timeout, api_calls=4, 600.0s) ---
            """;
        var parsedBatch = HelperReport.Parse(batch);
        Assert.NotNull(parsedBatch);
        Assert.Equal("deleg_abc123", parsedBatch!.DelegationId);
        Assert.Equal(2, parsedBatch.Tasks.Count);
        Assert.Equal(SubagentStatus.Completed, parsedBatch.Tasks[0].Status);
        Assert.Equal(SubagentStatus.Failed, parsedBatch.Tasks[1].Status);

        // JSON round-trip.
        var roundTrip = HelperReport.FromJson(parsedBatch.ToJson());
        Assert.Equal(parsedBatch, roundTrip);

        const string single = "[ASYNC DELEGATION — deleg_solo]\nOriginal goal: Check changelog\nStatus: interrupted\n";
        var parsedSingle = HelperReport.Parse(single);
        Assert.NotNull(parsedSingle);
        Assert.Equal("Check changelog", parsedSingle!.Tasks[0].Goal);
        Assert.Equal(SubagentStatus.Interrupted, parsedSingle.Tasks[0].Status);

        // Consolidated status summary wording.
        Assert.Equal("2 helpers working · 1 queued · 1 done · 1 failed · 1 stopped",
            HelperReport.SummarizeStatuses([
                SubagentStatus.Running, SubagentStatus.Running,
                SubagentStatus.Queued, SubagentStatus.Completed,
                SubagentStatus.Failed, SubagentStatus.Interrupted,
            ]));
        Assert.Equal("1 helper failed", HelperReport.SummarizeStatuses([SubagentStatus.Failed]));

        // HelperTailReport.Combine falls back cleanly to SubagentProgress when tail is unavailable/null.
        var child = new SubagentProgress
        {
            Id = "sa_1",
            Goal = "Verify build",
            Status = SubagentStatus.Completed,
            StartedAt = 100,
            UpdatedAt = 145,
            Summary = "All checks green",
            FilesWritten = ["a.cs"],
            FilesRead = ["b.cs"],
            Stream = [new SubagentStreamEntry(110, false, SubagentStreamKind.Tool, "Terminal")],
        };
        var fallback = HelperTailReport.Combine(child, null);
        Assert.False(fallback.Available);
        Assert.Equal("All checks green", fallback.Summary);
        Assert.Single(fallback.Steps);
        Assert.Equal(2, fallback.Files.Count);
        Assert.True(fallback.Files[0].Written);
        Assert.False(fallback.Files[1].Written);
    }

    // ------------------------------------------------------------------ 7. WinUI Source Verification Guards

    private static string WinSource(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (dir is not null && !File.Exists(Path.Combine(dir, "HermesHQ.sln")))
            dir = Directory.GetParent(dir)?.FullName;
        Assert.NotNull(dir);
        return File.ReadAllText(Path.Combine([dir!, "src", "HermesHQ.Windows", .. parts])).ReplaceLineEndings("\n");
    }

    [Fact]
    public void WinUiFiles_WireBackgroundShelf_SplitDetailView_FullHeadline_And_HelperTailDialog()
    {
        var panel = WinSource("Features", "Transcript", "BackgroundTasksPanel.cs");
        Assert.Contains("public const double WideWidth = 600;", panel);
        Assert.Contains("TimeSpan.FromSeconds(5)", panel);
        Assert.Contains("job.FullHeadline", panel);
        Assert.Contains("BackgroundProcessesApi.KillProcessAsync", panel);
        Assert.Contains("BackgroundProcessesApi.ListProcessesAsync", panel);
        Assert.Contains("\"Watching\"", panel);
        Assert.Contains("\"Output\"", panel);
        Assert.Contains("\"Folder\"", panel);
        Assert.Contains("\"Command\"", panel);
        Assert.Contains("Show All ", panel);
        Assert.Contains("Show Full Command", panel);

        var helpers = WinSource("Features", "Transcript", "HelperStatusRows.cs");
        Assert.Contains("ShowTailDialogAsync", helpers);
        Assert.Contains("BackgroundProcessesApi.ReadSubagentTailAsync", helpers);
        Assert.Contains("AcceptsReturn = true", helpers);
        // AcceptsReturn must come before Text on every multiline TextBox.
        Assert.True(helpers.IndexOf("AcceptsReturn = true", StringComparison.Ordinal) < helpers.IndexOf("Text = shown", StringComparison.Ordinal));

        var shelf = WinSource("Features", "Transcript", "ActivityShelf.cs");
        Assert.Contains("\"Background\"", shelf);
        Assert.Contains("BackgroundTasksPanel", shelf);
        Assert.Contains("HelperStatusRows.ShowTailDialogAsync", shelf);
        Assert.DoesNotContain("Title = \"Background Worker\"", shelf);
    }
}
