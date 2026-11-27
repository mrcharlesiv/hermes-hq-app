using System.Text.Json.Nodes;
using Hermes.Core.Insights;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Status & Maintenance and Usage (Tests/Pages/More/CommandCenterTests.swift): the lenient decoders against the stand-in
/// gateway's answers, a trimmed older gateway and bad data, the words, and the action polling state machine through
/// failed reads while the gateway restarts.
public class InsightsCommandCenterTests
{
    private static JsonNode? Json(string text) => J.Parse(text);

    private const string StatusGolden = """
    {"version": "0.21.5", "release_date": "2026.10.01", "config_version": 17, "latest_config_version": 17, "can_update_hermes": true,
     "gateway_running": true, "gateway_state": "running", "gateway_pid": 4242, "active_agents": 1, "active_sessions": 3,
     "hermes_home": "/home/hermes/.hermes", "overall": "degraded", "auth_required": true,
     "gateway_platforms": {"telegram": {"state": "connected"},
       "discord": {"state": "error", "error_message": "Login failed: the bot token was refused."},
       "slack": {"state": "disconnected"}}}
    """;

    [Fact]
    public void DecodesTheGatewaysStatus()
    {
        var s = GatewayStatusReport.Parse(Json(StatusGolden));
        Assert.Equal("Hermes 0.21.5", s.VersionWords);
        Assert.Equal("Running", s.GatewayWords);
        Assert.Equal("3", s.SessionsWords);
        Assert.True(s.CanUpdate);
        Assert.Equal(["Discord", "Slack", "Telegram"], s.Platforms.Select(p => p.Name));
        Assert.Equal(["Error", "Disconnected", "Connected"], s.Platforms.Select(p => p.Words));
        Assert.Equal("Login failed: the bot token was refused.", s.Platforms[0].Error);
        Assert.True(s.Platforms[0].IsDown && !s.Platforms[0].IsUp);
        Assert.True(s.Platforms[2].IsUp);
    }

    [Fact]
    public void ATrimmedOldGatewayStillReads()
    {
        var s = GatewayStatusReport.Parse(Json("""{"version": "0.19.0", "gateway_running": false, "active_sessions": "2"}"""));
        Assert.Equal("Hermes 0.19.0", s.VersionWords);
        Assert.Equal("Stopped", s.GatewayWords);
        Assert.Equal("2", s.SessionsWords);
        Assert.Empty(s.Platforms);
        Assert.True(s.CanUpdate);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("[]")]
    [InlineData("null")]
    [InlineData("7")]
    [InlineData("\"text\"")]
    [InlineData("""{"version": null, "gateway_running": "yes", "active_sessions": {}, "gateway_platforms": []}""")]
    public void BadStatusNeverCrashes(string text)
    {
        var s = GatewayStatusReport.Parse(Json(text));
        Assert.Equal("—", s.GatewayWords);
        Assert.Equal("—", s.SessionsWords);
        Assert.Equal("—", s.VersionWords);
        Assert.Empty(s.Platforms);
    }

    [Fact]
    public void OddPlatformsAndANumberVersion()
    {
        var s = GatewayStatusReport.Parse(Json("""{"version": 21, "gateway_platforms": {"api_server": "3", "sms": {"state": "ok"}, "x": {}}}"""));
        Assert.Equal("Hermes 21", s.VersionWords);
        Assert.Equal(["API Server", "SMS", "X"], s.Platforms.Select(p => p.Name));
        Assert.Equal(["3", "Connected", "—"], s.Platforms.Select(p => p.Words));
    }

    [Fact]
    public void PlatformNamesAndStates()
    {
        Assert.Equal("WhatsApp", GatewayStatusReport.PlatformName("whatsapp"));
        Assert.Equal("Home Assistant", GatewayStatusReport.PlatformName("home_assistant"));
        Assert.Equal("Matrix", GatewayStatusReport.PlatformName("matrix"));
        Assert.Equal("Connecting…", GatewayStatusReport.StateWords("retrying"));
        Assert.Equal("Rate limited", GatewayStatusReport.StateWords("rate_limited"));
        Assert.Equal("—", GatewayStatusReport.StateWords(""));
    }

    [Fact]
    public void TheDashboardsHeadline()
    {
        var s = GatewayStatusReport.Parse(Json(StatusGolden));
        var sum = StatusSummary.Of(s, null, online: true);
        Assert.Equal(("1 App Needs Attention", "Discord can’t connect.", StatusTone.Warning), (sum.Words, sum.Detail, sum.Tone));
        Assert.Equal("Not Connected", StatusSummary.Of(s, null, online: false).Words);
        Assert.Equal("Couldn’t Load Status", StatusSummary.Of(null, "Nope.", true).Words);
        Assert.Equal("Loading…", StatusSummary.Of(null, null, true).Words);
        var stopped = GatewayStatusReport.Parse(Json("""{"gateway_running": false}"""));
        Assert.Equal("Messaging Is Stopped", StatusSummary.Of(stopped, null, true).Words);
        var fine = GatewayStatusReport.Parse(Json("""{"gateway_running": true}"""));
        Assert.Equal(("Everything Is Running", "The gateway is up."), (StatusSummary.Of(fine, null, true).Words, StatusSummary.Of(fine, null, true).Detail));
        Assert.Equal("Discord, Slack, and Telegram", StatusSummary.ListWords(["Discord", "Slack", "Telegram"]));
    }

    [Fact]
    public void UpdateCheckWords()
    {
        var behind3 = HermesUpdateCheck.Parse(Json("""{"behind":3,"update_available":true,"can_apply":true,"current_version":"0.21.5"}"""));
        Assert.Equal("3 Updates Available", behind3.Words);
        Assert.True(behind3.CanUpdateNow);
        Assert.Equal("1 Update Available", HermesUpdateCheck.Parse(Json("""{"behind":1,"update_available":true,"can_apply":true}""")).Words);
        var current = HermesUpdateCheck.Parse(Json("""{"behind":0,"update_available":false,"can_apply":true}"""));
        Assert.Equal("Up to Date", current.Words);
        Assert.False(current.CanUpdateNow);
        Assert.Equal("Update Available", HermesUpdateCheck.Parse(Json("""{"behind":-1,"update_available":true,"can_apply":true}""")).Words);
        var unknown = HermesUpdateCheck.Parse(Json("""{"behind":null,"update_available":false}"""));
        Assert.Equal("Couldn’t Check", unknown.Words);
        Assert.True(unknown.CouldNotCheck);
        Assert.False(current.CouldNotCheck);
        var docker = HermesUpdateCheck.Parse(Json("""{"behind":2,"update_available":true,"can_apply":false,"message":"Pull the new image."}"""));
        Assert.Equal("2 Updates Available", docker.Words);
        Assert.False(docker.CanUpdateNow);
        Assert.Equal("Pull the new image.", docker.Message);
        foreach (var bad in new[] { "{}", "[]", "null", """{"behind":"x","message":""}""" })
        {
            var c = HermesUpdateCheck.Parse(Json(bad));
            Assert.Equal("Couldn’t Check", c.Words);
            Assert.True(c.CouldNotCheck);
            Assert.Null(c.Message);
        }
        var named = HermesUpdateCheck.Parse(Json("""{"behind":3,"update_available":true,"source_version":"v0.23.0"}"""));
        Assert.Equal("0.23.0 Available · 3 changes", named.UpdateWords);
    }

    [Fact]
    public void LinesLoseTheirEndingsAndBadOnesAreSkipped()
    {
        Assert.Equal(["a ERROR x", "b", "", "c"], LogLines.Parse(Json("""{"lines":["a ERROR x\n","b\r\n",4,"\n","c"]}""")));
        Assert.Empty(LogLines.Parse(Json("{}")));
        Assert.Empty(LogLines.Parse(Json("""{"lines":"nope"}""")));
        Assert.Empty(LogLines.Parse(Json("[]")));
    }

    [Fact]
    public void LevelOfALine()
    {
        Assert.Equal(LogLineLevel.Error, LogLines.Level("2026-10-13 19:16:26,793 ERROR gateway.platforms.telegram: Tool terminal exited"));
        Assert.Equal(LogLineLevel.Warning, LogLines.Level("2026-10-13 19:16:26,793 WARNING agent.loop: Slow provider answer"));
        Assert.Equal(LogLineLevel.Error, LogLines.Level("2026-10-13 19:16:26,793 CRITICAL x: y"));
        Assert.Equal(LogLineLevel.None, LogLines.Level("2026-10-13 19:16:26,793 INFO agent.loop: an ERROR in the message is not the level"));
        Assert.Equal(LogLineLevel.None, LogLines.Level("Traceback (most recent call last):"));
        Assert.Equal(LogLineLevel.None, LogLines.Level(""));
        Assert.Equal(LogLineLevel.None, LogLines.Level(new string('x', 4000)));
    }

    [Fact]
    public void TheLevelMenuSendsTheGatewaysOwnValues()
    {
        Dictionary<string, string> Q(LogLevelFilter l) => CommandCenterApi.LogsQuery(l).ToDictionary(p => p.Key, p => p.Value);
        Assert.Equal(new Dictionary<string, string> { ["file"] = "agent", ["lines"] = "200" }, Q(LogLevelFilter.All));
        Assert.Equal("ERROR", Q(LogLevelFilter.Errors)["level"]);
        Assert.Equal("WARNING", Q(LogLevelFilter.Warnings)["level"]);
        Assert.Equal(["All", "Errors", "Warnings"], LogLevels.Cases.Select(l => l.Title()));
        Assert.Equal("Couldn’t refresh. Showing the last lines.", LogLines.RefreshFailedText(LogLevelFilter.All, LogLevelFilter.All));
        Assert.Equal("Couldn’t load errors. Showing every level.", LogLines.RefreshFailedText(LogLevelFilter.All, LogLevelFilter.Errors));
        Assert.Equal("Couldn’t load all. Showing warnings only.", LogLines.RefreshFailedText(LogLevelFilter.Warnings, LogLevelFilter.All));
        Assert.Equal("The gateway’s recent log has no errors.", LogLines.EmptyText(LogLevelFilter.Errors));
        Assert.Equal(("No Logs", "No Warnings"), (LogLines.EmptyTitle(LogLevelFilter.All), LogLines.EmptyTitle(LogLevelFilter.Warnings)));
    }

    private const string UsageGolden = """
    {"daily": [{"input_tokens": 167271, "output_tokens": 17577, "sessions": 3, "day": "2026-10-07"},
               {"input_tokens": 47826, "output_tokens": 7270, "sessions": 2, "day": "2026-10-08"},
               {"input_tokens": 707895, "output_tokens": 76140, "sessions": 15, "day": "2026-10-09"}],
     "by_model": [{"model": "hermes-4", "input_tokens": 572055, "output_tokens": 62611, "estimated_cost": 2.6559, "sessions": 12},
                  {"model": "claude-opus-5", "input_tokens": 249117, "output_tokens": 27266, "estimated_cost": 1.1566, "sessions": 5}],
     "by_task": [], "period_days": 7,
     "totals": {"total_input": 922992, "total_output": 100987, "total_estimated_cost": 4.2838, "total_sessions": 20},
     "skills": {"top_skills": [{"skill": "release-notes", "view_count": 3, "manage_count": 1, "total_count": 4},
                               {"skill": "inbox-triage", "view_count": 2, "manage_count": 0}]}}
    """;

    [Fact]
    public void DecodesTheGatewaysUsage()
    {
        var u = UsageReport.Parse(Json(UsageGolden), 30);
        Assert.Equal(7, u.PeriodDays);
        Assert.Equal(1_023_979, u.Tokens);
        Assert.Equal(20, u.Sessions);
        Assert.Equal("$4.28", UsageFormat.Cost(u.Cost));
        Assert.Equal(["2026-10-07", "2026-10-08", "2026-10-09"], u.Daily.Select(d => d.Id));
        Assert.Equal([184_848L, 55_096, 784_035], u.Daily.Select(d => d.Tokens));
        Assert.Equal(["hermes-4", "claude-opus-5"], u.Models.Select(m => m.Id));
        Assert.Equal(634_666, u.Models[0].Tokens);
        Assert.Equal([new UsageReport.Skill("release-notes", 4), new UsageReport.Skill("inbox-triage", 2)], u.Skills);
        Assert.False(u.IsEmpty);
        Assert.StartsWith("Daily tokens, 3 days. Most on October 9: 784K.", u.ChartSummary(System.Globalization.CultureInfo.GetCultureInfo("en-US")));
        // The dashboard's tiles.
        Assert.Equal("923K read · 101K written", u.TokensNote);
        Assert.Equal("about 7 a day", u.SessionsNote);
        Assert.Equal("about $1.43 a day", u.CostNote);
        Assert.Equal("2026-10-09", u.Peak?.Id);
        Assert.Equal("12 sessions · $2.66", UsageFormat.ModelLine(u.Models[0]));
    }

    [Fact]
    public void ATrimmedOldUsageStillReads()
    {
        var u = UsageReport.Parse(Json("""
        {"daily": [{"day": "2026-10-09", "input_tokens": "1200", "output_tokens": 300, "sessions": 1}, {"sessions": 1},
                   {"day": "2026-10-09", "input_tokens": 9}, {"day": "soon"}, "x", null],
         "by_model": [{"model": "hermes-4", "input_tokens": null, "output_tokens": "1200"}, {"sessions": 2}, {"model": "hermes-4"}, 4],
         "totals": {"total_input": "1200", "total_output": null, "total_sessions": "1"}}
        """), 30);
        Assert.Equal(30, u.PeriodDays);
        Assert.Equal(1200, u.Tokens);
        Assert.Equal(1, u.Sessions);
        Assert.Equal("—", UsageFormat.Cost(u.Cost));
        Assert.Equal([1500L], u.Daily.Select(d => d.Tokens));
        Assert.Equal([new UsageReport.Model("hermes-4", 1200, null, null)], u.Models);
        Assert.Empty(u.Skills);
    }

    [Fact]
    public void NobodyUsedItYet()
    {
        var u = UsageReport.Parse(Json("""
        {"daily": [], "by_model": [], "period_days": 90, "skills": {"summary": {}, "top_skills": []},
         "totals": {"total_input": null, "total_output": null, "total_estimated_cost": 0, "total_sessions": 0, "total_api_calls": null}}
        """), 90);
        Assert.True(u.IsEmpty);
        Assert.Null(u.Tokens);
        Assert.Equal("—", UsageFormat.Compact(u.Tokens));
        Assert.Equal("Daily tokens, 0 days", u.ChartSummary());
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("[]")]
    [InlineData("""{"daily": {}, "by_model": "x", "totals": [], "skills": 4}""")]
    [InlineData("""{"daily": [[1]], "totals": {"total_input": {}, "total_estimated_cost": "abc"}, "skills": {"top_skills": [{"skill": ""}, {"skill": 3}]}}""")]
    public void BadUsageNeverCrashes(string text)
    {
        var u = UsageReport.Parse(Json(text), 7);
        Assert.True(u.IsEmpty);
        Assert.Equal(7, u.PeriodDays);
        Assert.True(u.Daily.Count == 0 && u.Models.Count == 0 && u.Skills.Count == 0);
    }

    [Fact]
    public void NumbersInWords()
    {
        Assert.Equal("0", UsageFormat.Compact(0));
        Assert.Equal("950", UsageFormat.Compact(950));
        Assert.Equal("1K", UsageFormat.Compact(1000));
        Assert.Equal("12.3K", UsageFormat.Compact(12_340));
        Assert.Equal("1000K", UsageFormat.Compact(999_949));
        Assert.Equal("1M", UsageFormat.Compact(999_950));
        Assert.Equal("1.2M", UsageFormat.Compact(1_234_567));
        Assert.Equal("185K", UsageFormat.Compact(184_848));
        Assert.Equal("2.5B", UsageFormat.Compact(2_500_000_000));
        Assert.Equal("$12.35", UsageFormat.Cost(12.3456));
        Assert.Equal("<$0.01", UsageFormat.Cost(0.004));
        Assert.Equal("$0.00", UsageFormat.Cost(0));
        Assert.Equal("—", UsageFormat.Cost(double.NaN));
        Assert.Equal("—", UsageFormat.Cost(null));
        Assert.Equal("$12.3K", UsageFormat.Cost(12_345.6));
        Assert.Equal("1 session", UsageFormat.Sessions(1));
        Assert.Equal("—", UsageFormat.Sessions(null));
        Assert.Equal("1 action", UsageFormat.Actions(1));
        Assert.Equal("4 actions", UsageFormat.Actions(4));
        Assert.Equal("Last 7 Days", UsageFormat.Period(7));
        Assert.Equal("Couldn’t load 90 days. Showing the last 30 days.", UsageFormat.RefreshFailedText(30, 90));
    }

    [Fact]
    public void ADayIsReadAsTheCalendarDay()
    {
        Assert.Equal(new DateTime(2026, 10, 9), UsageReport.ParseDate("2026-10-09"));
        Assert.Null(UsageReport.ParseDate("2026-13-01"));
        Assert.Null(UsageReport.ParseDate(""));
        Assert.NotNull(UsageReport.ParseDate("2026-10-09T10:00:00"));
    }

    [Fact]
    public void MaintenanceWords()
    {
        Assert.Equal(["Run Doctor", "Security Audit", "Create Backup"], Maintenance.Cases.Select(a => a.Title()));
        Assert.Equal("Zip config, memories, skills, and sessions on the computer running Hermes", MaintenanceAction.Backup.Detail());
        Assert.Null(MaintenanceAction.SecurityAudit.Body());
        Assert.NotNull(MaintenanceAction.Doctor.Body());
        Assert.Equal("Finished with Problems", ActionWords.MaintenanceWords(new ActionPhase.Finished(false, null))?.Text);
        Assert.Equal("Running…", ActionWords.MaintenanceWords(ActionPhase.Running)?.Text);
        Assert.Null(ActionWords.MaintenanceWords(ActionPhase.Idle));
        Assert.Equal("Gateway Restarted", GatewayRestartWords.Words(new ActionPhase.Finished(true, "x"))?.Text);
        Assert.Equal("port in use", GatewayRestartWords.Words(new ActionPhase.Finished(false, "port in use"))?.Text);
        Assert.Equal("The gateway didn’t restart.", GatewayRestartWords.Words(new ActionPhase.Finished(false, null))?.Text);
        Assert.Equal(["b", "c"], ActionWords.Tail(["=== x ===", "a", "", "b", "c"], 2));
    }

    [Fact]
    public void ActionStatusIsLenient()
    {
        var running = GatewayActionStatus.Parse(Json("""{"name":"doctor","running":true,"exit_code":null,"pid":5,"lines":["a",1,null,"b"]}"""), "x");
        Assert.Equal(("doctor", true, (int?)null), (running.Name, running.Running, running.ExitCode));
        Assert.Equal(["a", "1", "b"], running.Lines);
        var done = GatewayActionStatus.Parse(Json("""{"exit_code":"1","lines":["oops",""," "]}"""), "doctor");
        Assert.True(done.Name == "doctor" && !done.Running && done.ExitCode == 1 && done.LastLine == "oops");
        var empty = GatewayActionStatus.Parse(Json("[]"), "doctor");
        Assert.True(empty.Running && empty.Lines.Count == 0);
    }

    // ------------------------------------------------------------------ the poll

    /// Answers scripted one read at a time; the last one repeats.
    private sealed class Script(params object[] steps)
    {
        private readonly Queue<object> _steps = new(steps);
        public int Reads;
        public Task<GatewayActionStatus> Next(string name, CancellationToken _)
        {
            Interlocked.Increment(ref Reads);
            object step;
            lock (_steps) step = _steps.Count > 1 ? _steps.Dequeue() : _steps.Peek();
            return step switch
            {
                "fail" => throw new GatewayException("offline", "Can't reach the gateway."),
                "404" => throw new GatewayException("http", "The gateway answered 404.", 404, """{"detail":"Not Found"}"""),
                GatewayActionStatus s => Task.FromResult(s with { Name = name }),
                _ => throw new InvalidOperationException(),
            };
        }
    }

    private static GatewayActionStatus S(bool running, int? exit, params string[] lines) => new("", running, exit, lines);

    private static async Task Until(Func<bool> done, int seconds = 10)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (!done())
        {
            if (DateTime.UtcNow > end) throw new TimeoutException("condition not met");
            await Task.Delay(10);
        }
    }

    [Fact]
    public async Task ARestartRunsThroughFailedReadsToItsEnd()
    {
        var script = new Script(S(true, null, "Stopping gateway…"), "fail", "fail", "fail",
            S(true, null, "Stopping gateway…", "Starting gateway…"),
            S(false, 0, "Stopping gateway…", "Starting gateway…", "✓ Gateway restarted", ""));
        var run = new GatewayActionRun(script.Next) { Interval = TimeSpan.FromMilliseconds(15), Patience = TimeSpan.FromSeconds(30) };
        var finished = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        run.OnFinish = ok => finished.SetResult(ok);
        run.Start(() => Task.FromResult("gateway-restart"));
        Assert.True(run.Phase is ActionPhase.RunningPhase && run.IsBusy);
        Assert.Equal("Restarting…", GatewayRestartWords.Words(run.Phase)?.Text);
        Assert.True(await finished.Task.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.False(run.IsBusy);
        Assert.Equal(new ActionPhase.Finished(true, "✓ Gateway restarted"), run.Phase);
        Assert.Equal(4, run.Lines.Count);
        Assert.Equal(6, script.Reads);
    }

    [Fact]
    public async Task ANotYetRegisteredActionIsNotItsEnd()
    {
        // Not running, no exit code, never seen running: an older run's status, or not registered yet.
        var script = new Script(S(false, null), S(true, null, "a"), S(false, null, "a", "b"));
        var run = new GatewayActionRun(script.Next) { Interval = TimeSpan.FromMilliseconds(15) };
        run.Start(() => Task.FromResult("doctor"));
        await Until(() => !run.IsBusy);
        Assert.Equal(new ActionPhase.Finished(true, "b"), run.Phase);
        Assert.True(script.Reads >= 3);
    }

    [Fact]
    public async Task AStatusThatIsNotThereIsUntracked()
    {
        var script = new Script("404");
        var run = new GatewayActionRun(script.Next) { Interval = TimeSpan.FromMilliseconds(15) };
        var untracked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        run.OnUntracked = () => untracked.SetResult();
        run.Start(() => Task.FromResult("gateway-restart"));
        await untracked.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.False(run.IsBusy);
        Assert.IsType<ActionPhase.UntrackedPhase>(run.Phase);
        Assert.Equal(GatewayRestartWords.UntrackedText, GatewayRestartWords.Words(run.Phase)?.Text);
    }

    [Fact]
    public async Task NoAnswerForTooLongStalls()
    {
        var script = new Script("fail");
        var run = new GatewayActionRun(script.Next) { Interval = TimeSpan.FromMilliseconds(10), Patience = TimeSpan.FromMilliseconds(80) };
        run.Start(() => Task.FromResult("gateway-restart"));
        await Until(() => run.Phase is ActionPhase.StalledPhase);
        Assert.True(run.IsBusy);
        Assert.Equal("Still restarting. This page updates when your gateway is back.", GatewayRestartWords.Words(run.Phase)?.Text);
        run.Reset();
        Assert.IsType<ActionPhase.IdlePhase>(run.Phase);
    }

    [Fact]
    public async Task AStartThatFailsSaysWhy()
    {
        var run = new GatewayActionRun(new Script(S(false, 0)).Next) { Interval = TimeSpan.FromMilliseconds(10) };
        var finished = new List<bool>();
        run.OnFinish = ok => finished.Add(ok);
        run.Start(() => Task.FromException<string>(new GatewayException("http", "500", 500, """{"detail":"Failed to restart gateway: launchctl answered 5"}""")));
        await Until(() => !run.IsBusy);
        Assert.Equal(new ActionPhase.Failed("Failed to restart gateway: launchctl answered 5"), run.Phase);
        Assert.Equal([false], finished);
    }

    [Fact]
    public void ReasonsInWords()
    {
        Assert.Equal(InsightsWire.OlderHermes, InsightsWire.Reason(new GatewayException("http", "x", 404, """{"detail":"Not Found"}""")));
        Assert.Equal("Session not found", InsightsWire.Reason(new GatewayException("http", "x", 404, """{"detail":"Session not found"}""")));
        Assert.Equal("Nope", InsightsWire.Reason(new GatewayException("http", "x", 400, """{"detail":{"message":"Nope"}}""")));
        Assert.Equal(InsightsWire.CouldntDoThat, InsightsWire.Reason(new GatewayException("http", "x", 500, "<html>")));
        Assert.True(InsightsWire.IsNotAvailable(new GatewayException("rpc", "Method not found", rpcCode: -32601)));
        Assert.StartsWith("Can’t reach the computer running Hermes.", InsightsWire.Reason(new GatewayException("offline", "x")));
        Assert.Equal("token=… and Bearer …", InsightsWire.Scrubbed("token=abc123 and Bearer abcdefghijkl"));
        Assert.Equal("Star Map", InsightsWire.PageName("Couldn’t Load Star Map"));
        Assert.Equal("This Hermes doesn’t have Usage. Updating Hermes may add it.", InsightsWire.NotAvailableBody("Usage"));
    }
}
