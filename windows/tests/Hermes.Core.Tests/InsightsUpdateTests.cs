using System.Text.Json.Nodes;
using Hermes.Core.Insights;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// The one Update sheet's pure parts (Tests/Pages/More/HermesUpdateFlowTests.swift): the check's and the receipt's
/// lenient decoding, the drain line parser, the steps from status polls (the restart gap, a failed install), how an
/// update ends; and a whole run of `HermesUpdate` against a scripted gateway.
public class InsightsUpdateTests
{
    private static JsonNode? Json(string text) => J.Parse(text);

    [Fact]
    public void DecodesTheCheckWithCommits()
    {
        var check = HermesUpdateCheck.Parse(Json("""
        {"install_method": "git", "current_version": "0.22.5", "behind": 3, "update_available": true, "can_apply": true,
         "update_command": "hermes update", "channel": "stable", "source_version": "0.23.0", "held": null,
         "commits": [{"sha": "2bd378e", "summary": "Gateways drain first", "author": "teknium", "at": 1762300000},
                     {"sha": "", "summary": ""}, {"summary": "No sha"}]}
        """));
        Assert.Equal("git", check.InstallMethod);
        Assert.Equal("0.22.5", check.CurrentVersion);
        Assert.Equal("0.23.0", check.SourceVersion);
        Assert.Equal(3, check.Behind);
        Assert.True(check.UpdateAvailable);
        Assert.Equal(["Gateways drain first", "No sha"], check.Commits.Select(c => c.Summary));
        Assert.Equal("teknium", check.Commits[0].Author);
        var older = HermesUpdateCheck.Parse(Json("""{"behind": 0, "update_available": false, "current_version": ""}"""));
        Assert.Null(older.CurrentVersion);
        Assert.Empty(older.Commits);
        Assert.Null(older.InstallMethod);
    }

    [Fact]
    public void DecodesTheReceiptAndARefusal()
    {
        var r = HermesUpdateReceipt.Parse(Json("""
        {"outcome": "Partial", "action_id": "a1", "pre_sha": "aaa", "post_sha": "bbb", "post_version": "0.23.0",
         "followups": [{"step": "restart_dashboard", "reason": "Restart the dashboard"}, {"reason": "no step"}],
         "user_action": {"step": "node", "reason": "Install Node 22, then run hermes update again"}}
        """));
        Assert.Equal("partial", r?.Outcome);
        Assert.True(r?.Succeeded);
        Assert.Equal("0.23.0", r?.PostVersion);
        Assert.Single(r!.Followups);
        Assert.Equal("Install Node 22, then run hermes update again", r.Owed);
        Assert.Null(HermesUpdateReceipt.Parse(Json("[]")));
        Assert.Null(HermesUpdateReceipt.Parse(null));

        var status = GatewayActionStatus.Parse(Json("""
        {"name": "hermes-update", "running": false, "exit_code": 0, "lines": ["✓ Update complete! (v0.22.5 → v0.23.0)"],
         "receipt": {"outcome": "success", "post_version": "0.23.0"}}
        """), "hermes-update");
        Assert.True(status.Receipt?.Succeeded);
        Assert.Equal(("0.22.5", "0.23.0"), HermesUpdateLog.Completed(status.Lines));

        var refusal = HermesUpdateRefusal.Parse(Json("""{"ok": false, "error": "docker_update_unsupported", "message": "Pull the new image.", "update_command": "docker compose pull"}"""));
        Assert.Equal("docker_update_unsupported", refusal?.Code);
        Assert.Equal("docker compose pull", refusal?.Command);
        Assert.Null(HermesUpdateRefusal.Parse(Json("""{"ok": true, "name": "hermes-update"}""")));
        Assert.Equal("Hermes runs in a Docker container here", HermesInstallWords.Method(refusal?.Code));
    }

    [Fact]
    public void ProfilesFromLabels()
    {
        Assert.Equal("default", HermesUpdateLog.Profile("ai.hermes.gateway"));
        Assert.Equal("finance", HermesUpdateLog.Profile("ai.hermes.gateway-finance"));
        Assert.Equal("gym", HermesUpdateLog.Profile("hermes-gateway-gym.service"));
        Assert.Equal("default", HermesUpdateLog.Profile("hermes-gateway.service"));
        Assert.Null(HermesUpdateLog.Profile("gateway PID 4012"));
    }

    [Fact]
    public void ReadsThePosixPauseAndTheFleetDrain()
    {
        string[] lines = ["→ Checking for updates…",
            "  ⏳ Waiting up to 1905s for in-flight turns on ai.hermes.gateway, ai.hermes.gateway-finance to finish before the update...",
            "    ⏳ still draining — 1875s left before the forced restart",
            "    waiting on 2 active work unit(s):",
            "      • finance: telegram turn"];
        var d = HermesUpdateLog.Drain(lines);
        Assert.Equal(["default", "finance"], d?.Profiles);
        Assert.Equal((1905, 1875, 2, false), (d!.Budget, d.Left, d.Units, d.Over));
        Assert.Equal(HermesUpdateLog.Stage.Drain, HermesUpdateLog.StageOf(lines));
        var fleet = HermesUpdateLog.Drain(["→ ai.hermes.gateway: draining (up to 600s)...", "→ ai.hermes.gateway-gym: draining (up to 900s)..."]);
        Assert.Equal(["default", "gym"], fleet?.Profiles);
        Assert.Equal(900, fleet?.Budget);
        string[] over = ["  ⏳ Waiting up to 60s for in-flight turns on ai.hermes.gateway to finish before the update...",
            "⏸ Paused for the update: ai.hermes.gateway", "Installing Python dependencies…"];
        Assert.True(HermesUpdateLog.Drain(over)?.Over);
        Assert.Equal(HermesUpdateLog.Stage.Install, HermesUpdateLog.StageOf(over));
        Assert.Null(HermesUpdateLog.Drain(["⏸ Paused for the update: none busy", "Installing"]));
    }

    [Fact]
    public void DrainWords()
    {
        var p = new HermesUpdateProgress();
        var now = DateTimeOffset.FromUnixTimeSeconds(1000);
        p.Read(new GatewayActionStatus("hermes-update", true, null,
            ["  ⏳ Waiting up to 1905s for in-flight turns on ai.hermes.gateway-finance, ai.hermes.gateway-gym to finish"]), now);
        var names = new Dictionary<string, string> { ["finance"] = "Finance", ["gym"] = "Gym" };
        Assert.Equal("Finishing replies on Finance and Gym · up to 32 min", p.DrainDetail(n => names.GetValueOrDefault(n, n), now));
        Assert.Equal(HermesUpdateStepState.Active, p.State(HermesUpdateStepId.Drain));
    }

    private static GatewayActionStatus St(IEnumerable<string> lines, bool running = true, int? exit = null, string? receipt = null) =>
        new("hermes-update", running, exit, [.. lines], receipt == null ? null : HermesUpdateReceipt.Parse(Json(receipt)));

    [Fact]
    public void WalksThroughEveryStep()
    {
        var p = new HermesUpdateProgress();
        var lines = new List<string> { "→ Checking for updates…" };
        p.Read(St(lines));
        Assert.Equal(HermesUpdateStepState.Done, p.State(HermesUpdateStepId.Check));
        Assert.Equal(HermesUpdateStepState.Waiting, p.State(HermesUpdateStepId.Drain));
        lines.Add("  ⏳ Waiting up to 600s for in-flight turns on ai.hermes.gateway to finish before the update...");
        p.Read(St(lines));
        Assert.Equal(HermesUpdateStepState.Active, p.State(HermesUpdateStepId.Drain));
        lines.Add("⏸ Paused for the update: ai.hermes.gateway");
        lines.Add("Installing Python dependencies…");
        p.Read(St(lines));
        Assert.Equal(HermesUpdateStepState.Done, p.State(HermesUpdateStepId.Drain));
        Assert.Equal(HermesUpdateStepState.Active, p.State(HermesUpdateStepId.Install));
        lines.Add("▶ Restarted paused gateway(s): ai.hermes.gateway");
        p.Read(St(lines));
        Assert.Equal(HermesUpdateStepState.Done, p.State(HermesUpdateStepId.Install));
        Assert.Equal(HermesUpdateStepState.Active, p.State(HermesUpdateStepId.Restart));
        lines.Add("✓ Update complete! (v0.22.5 → v0.23.0)");
        p.Read(St(lines, running: false, exit: 0));
        Assert.True(p.Finished);
        Assert.Equal(HermesUpdateStepState.Done, p.State(HermesUpdateStepId.Restart));
        Assert.Equal(HermesUpdateStepState.Active, p.State(HermesUpdateStepId.Confirm));
    }

    [Fact]
    public void TheRestartGapMovesOnToRestartButNotBeforeTheInstall()
    {
        var p = new HermesUpdateProgress();
        string[] lines = ["⏸ Paused for the update: ai.hermes.gateway", "Installing Python dependencies…"];
        p.Read(St(lines));
        Assert.Equal(HermesUpdateStepState.Skipped, p.State(HermesUpdateStepId.Drain));
        p.Unanswered();
        Assert.True(p.SawGap);
        p.Read(St(lines));
        Assert.Equal(HermesUpdateStepState.Done, p.State(HermesUpdateStepId.Install));
        Assert.Equal(HermesUpdateStepState.Active, p.State(HermesUpdateStepId.Restart));
        var early = new HermesUpdateProgress();
        early.Read(St(["→ Checking for updates…"]));
        early.Unanswered();
        Assert.False(early.SawGap);
    }

    [Fact]
    public void AFailedInstallStopsOnTheInstall()
    {
        var p = new HermesUpdateProgress();
        string[] lines = ["⚕ Updating Hermes Agent…", "→ Installing dependencies…", "✗ Update failed. Nothing was changed."];
        p.Read(St(lines));
        p.Read(St(lines, running: false, exit: 1));
        Assert.True(p.Finished);
        Assert.Equal(HermesUpdateStepState.Active, p.State(HermesUpdateStepId.Install));
        Assert.Equal(HermesUpdateStepState.Waiting, p.State(HermesUpdateStepId.Restart));
        var r = new HermesUpdateProgress();
        r.Read(St(["Installing"], running: false, receipt: """{"outcome": "failed", "user_action": {"reason": "Fix the conflicts"}}"""));
        Assert.True(r.Finished);
        Assert.Equal(1, r.ExitCode);
    }

    [Fact]
    public void HowAnUpdateEnds()
    {
        var ok = HermesUpdateReceipt.Parse(Json("""{"outcome": "success", "pre_sha": "a", "post_sha": "b", "post_version": "0.23.0"}"""));
        Assert.Equal(new HermesUpdateEnd.Updated("v0.23.0"), HermesUpdateEnd.Gateway(0, ok, "0.22.5", "v0.23.0", []));
        Assert.Equal(new HermesUpdateEnd.Unchanged("v0.22.5"), HermesUpdateEnd.Gateway(0, ok, "0.22.5", "v0.22.5", []));
        Assert.IsType<HermesUpdateEnd.Unconfirmed>(HermesUpdateEnd.Gateway(0, ok, "0.22.5", null, []));
        Assert.Equal(new HermesUpdateEnd.Updated("0.23.0"), HermesUpdateEnd.Gateway(0, ok, null, "0.23.0", []));
        Assert.IsType<HermesUpdateEnd.Unconfirmed>(HermesUpdateEnd.Gateway(0, null, null, "0.23.0", []));
        string[] lines = ["Installing", "✗ Update pulled new code, but restoring local changes hit conflicts.", "=== hermes-update failed ==="];
        Assert.Equal(new HermesUpdateEnd.Failed("Update pulled new code, but restoring local changes hit conflicts."),
            HermesUpdateEnd.Gateway(1, null, "0.22.5", "0.22.5", lines));
        var owed = HermesUpdateReceipt.Parse(Json("""{"outcome": "failed", "user_action": {"reason": "Install Node 22"}}"""));
        Assert.Equal(new HermesUpdateEnd.Failed("Install Node 22"), HermesUpdateEnd.Gateway(1, owed, "0.22.5", null, lines));
        Assert.False(HermesUpdateEnd.StopsReading(3, null));
        Assert.False(HermesUpdateEnd.StopsReading(17, null));
        Assert.False(HermesUpdateEnd.StopsReading(3, 0));
        Assert.False(HermesUpdateEnd.StopsReading(2, 1));
        Assert.True(HermesUpdateEnd.StopsReading(3, 1));
    }

    [Fact]
    public void Words()
    {
        Assert.Equal("0.22.5 → 0.23.0", HermesUpdateWords.Versions("v0.22.5", "0.23.0"));
        Assert.Equal("A, B and C", HermesUpdateWords.List(["A", "B", "C"]));
        Assert.Equal("1 hr 5 min", HermesUpdateWords.Minutes(3900));
        Assert.Equal("1 min", HermesUpdateWords.Minutes(20));
        Assert.Equal("under a minute", HermesUpdateWords.Minutes(0));
        Assert.Equal("0:42", HermesUpdateWords.Elapsed(42));
        Assert.Equal("1:02:03", HermesUpdateWords.Elapsed(3723));
    }

    // ------------------------------------------------------------------ a whole run against a scripted gateway

    private sealed class FakeGateway : IGatewayRest
    {
        public string Version = "0.21.5";
        public bool Refuse;
        public int StatusReads;
        public List<string> Calls { get; } = [];
        public string Check = """{"behind": 3, "update_available": true, "can_apply": true, "current_version": "0.21.5", "source_version": "0.22.0", "commits": [{"sha": "a", "summary": "One"}]}""";
        public Func<int, string> Status = n => n < 2
            ? """{"name": "hermes-update", "running": true, "lines": ["⚕ Updating Hermes Agent…", "→ Installing dependencies…"]}"""
            : """{"name": "hermes-update", "running": false, "exit_code": 0, "lines": ["⚕ Updating Hermes Agent…", "→ Installing dependencies…", "→ Restarting gateway…", "✓ Update complete! (v0.21.5 → v0.22.0)"]}""";

        /// The update's status reads wait for this (open by default). A test that looks at the run while it works holds
        /// it shut, so the scripted update can't reach its end (three reads, 10 ms apart) before those checks run.
        public Task StatusReadsOpen = Task.CompletedTask;

        public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query, JsonNode? body, TimeSpan timeout, CancellationToken ct = default)
        {
            if (path == "/api/actions/hermes-update/status" && !StatusReadsOpen.IsCompleted)
                return StatusReadsOpen.ContinueWith(_ => JsonAsync(method, path, query, body, timeout, ct), TaskScheduler.Default).Unwrap();
            lock (Calls) Calls.Add($"{method} {path}");
            string answer = (method.Method, path) switch
            {
                ("GET", "/api/hermes/update/check") => Check,
                ("POST", "/api/hermes/update") => Refuse
                    ? """{"ok": false, "error": "docker_update_unsupported", "message": "Pull the image.", "update_command": "docker compose pull"}"""
                    : """{"ok": true, "name": "hermes-update"}""",
                ("GET", "/api/actions/hermes-update/status") => Status(Interlocked.Increment(ref StatusReads) - 1),
                ("GET", "/api/status") => $$"""{"version": "{{Version}}"}""",
                ("GET", "/api/hermes/update/receipt") => throw new GatewayException("http", "404", 404, """{"detail":"Not Found"}"""),
                _ => throw new InvalidOperationException(path),
            };
            if (path == "/api/actions/hermes-update/status" && answer.Contains("\"exit_code\": 0")) Version = "0.22.0";
            return Task.FromResult(J.Parse(answer));
        }
    }

    private static async Task Until(Func<bool> done, int seconds = 15)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (!done())
        {
            if (DateTime.UtcNow > end) throw new TimeoutException("condition not met");
            await Task.Delay(10);
        }
    }

    private static HermesUpdate Run(FakeGateway gw, string key) => new(key, "Studio", HermesUpdate.PlaceWords(true, "studio.local:9119"), new HermesUpdateApi(gw))
    {
        PollInterval = TimeSpan.FromMilliseconds(10), VersionReadDelay = TimeSpan.FromMilliseconds(10),
    };

    [Fact]
    public async Task ChecksAsksThenUpdatesAndConfirmsTheNewVersion()
    {
        // The status reads stay shut until the run has been looked at while it works: on a busy machine the scripted
        // update could otherwise end between Confirm() and the next line.
        var reads = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var gw = new FakeGateway { StatusReadsOpen = reads.Task };
        var key = "test-" + Guid.NewGuid();
        var run = HermesUpdateCenter.Shared.Update(key, () => Run(gw, key));
        await Until(() => run.Phase == HermesUpdate.PhaseKind.Asking);
        Assert.Equal("Update Hermes on Studio", run.Headline);
        Assert.Equal("0.21.5 → 0.22.0", run.Versions);
        Assert.Equal("Gateway in use · studio.local:9119", run.Place);
        Assert.Equal(HermesUpdate.AskingLine, run.Line);
        Assert.True(run.ShowsSteps && run.ShowsWhatsNew);
        Assert.Equal(["Check", "Wait for Bots", "Install", "Restart", "Confirm"], run.Steps.Select(s => s.Title));
        Assert.Equal("Bots finish the replies they’re working on first. This can take a while.", run.Steps[1].Detail);
        Assert.Equal("Update", HermesUpdateCenter.Shared.RowStatus(key));
        run.Confirm();
        Assert.Equal(HermesUpdate.PhaseKind.Working, run.Phase);
        Assert.Equal("Updating…", HermesUpdateCenter.Shared.RowStatus(key));
        reads.SetResult();
        await Until(() => run.Phase == HermesUpdate.PhaseKind.Ended);
        Assert.Equal(new HermesUpdateEnd.Updated("0.22.0"), run.End);
        Assert.Equal("Updated to 0.22.0", run.Headline);
        Assert.Equal("Studio is back and running the new Hermes.", run.Line);
        Assert.Equal("0.21.5 → 0.22.0", run.Versions);
        Assert.All(run.Steps.Where(s => s.Id != HermesUpdateStepId.Drain), s => Assert.Equal(HermesUpdateStepState.Done, s.State));
        Assert.Equal(HermesUpdateStepState.Skipped, run.Steps[1].State);
        Assert.Equal("No bots were busy", HermesUpdate.StepDetail(run.Steps[1]));
        Assert.True(run.HasOutput);
        Assert.False(HermesUpdateCenter.Shared.CheckFor(key)!.UpdateAvailable);
        var after = false;
        run.AfterUpdated = () => after = true;
        run.SheetClosed();
        Assert.True(after);
        Assert.Null(HermesUpdateCenter.Shared.Run(key));
    }

    [Fact]
    public async Task ARefusalSaysWhatToRunInstead()
    {
        var gw = new FakeGateway { Refuse = true };
        var run = Run(gw, "refused");
        run.Check();
        await Until(() => run.Phase == HermesUpdate.PhaseKind.Asking);
        run.Confirm();
        await Until(() => run.Phase == HermesUpdate.PhaseKind.Ended);
        Assert.Equal(new HermesUpdateEnd.CantUpdateHere("Hermes runs in a Docker container here", "docker compose pull"), run.End);
        Assert.Equal("Studio Can’t Update Itself", run.Headline);
        Assert.Equal("Hermes runs in a Docker container here. Run this on Studio to update it:", run.Line);
        Assert.Equal("docker compose pull", run.CommandToCopy);
        Assert.False(run.ShowsSteps);
    }

    [Fact]
    public async Task EndingsBeforeTheQuestion()
    {
        var upToDate = Run(new FakeGateway { Check = """{"behind": 0, "update_available": false, "can_apply": true, "current_version": "0.22.0"}""" }, "a");
        upToDate.Check();
        await Until(() => upToDate.End != null);
        Assert.Equal("Hermes Is Up to Date", upToDate.Headline);
        Assert.Equal("Studio runs the newest Hermes. Nothing to do.", upToDate.Line);
        Assert.Equal("0.22.0", upToDate.Versions);

        var docker = Run(new FakeGateway { Check = """{"behind": 2, "update_available": true, "can_apply": false, "install_method": "docker"}""" }, "b");
        docker.Check();
        await Until(() => docker.End != null);
        Assert.Equal("Hermes runs in a Docker container here, so it’s updated wherever it’s run from, not from here.", docker.Line);

        var couldnt = Run(new FakeGateway { Check = """{"behind": null, "update_available": false}""" }, "c");
        couldnt.Check();
        await Until(() => couldnt.End != null);
        Assert.True(couldnt.CheckFailed);
        Assert.Equal("Couldn’t Check for Updates", couldnt.Headline);
        Assert.Equal("Hermes couldn’t reach its update source. Try again later.", couldnt.Line);
        Assert.Contains("Update Hermes on Studio", couldnt.Details());
    }

    [Fact]
    public async Task AFailedUpdateStopsOnItsStepAndSaysWhy()
    {
        var gw = new FakeGateway
        {
            Status = n => n < 1
                ? """{"running": true, "lines": ["⚕ Updating Hermes Agent…", "→ Installing dependencies…"]}"""
                : """{"running": false, "exit_code": 1, "lines": ["⚕ Updating Hermes Agent…", "→ Installing dependencies…", "✗ Update failed. Nothing was changed."]}""",
        };
        var run = Run(gw, "failed");
        run.Check();
        await Until(() => run.Phase == HermesUpdate.PhaseKind.Asking);
        run.Confirm();
        await Until(() => run.Phase == HermesUpdate.PhaseKind.Ended, 20);
        Assert.Equal(new HermesUpdateEnd.Failed("Update failed. Nothing was changed."), run.End);
        Assert.Equal("The Update Didn’t Finish", run.Headline);
        Assert.Equal(HermesUpdateStepState.Failed, run.Steps.First(s => s.Id == HermesUpdateStepId.Install).State);
        Assert.Equal(HermesUpdateStepState.Waiting, run.Steps.First(s => s.Id == HermesUpdateStepId.Restart).State);
        Assert.True(run.ShowsSteps);
    }
}
