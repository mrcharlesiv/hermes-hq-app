using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Insights;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Status & Maintenance, Usage and Update Hermes against the More pages' stand-in (windows/ci/fixtures/morepages-gateway.py,
/// its `actions` module): the status and its platforms, the update check, logs by level, usage by period, Restart Gateway
/// through the socket dropping, the maintenance actions with their output, and an update from the question to "Updated
/// to 0.22.0" read back from /api/status. Run through windows/scripts/e2e.sh (HQW_E2E_INSIGHTS_STATUS); without it
/// these pass vacuously.
[Trait("Category", "E2E")]
[Collection("Insights status E2E")]
public class InsightsCommandCenterEndToEndTests
{
    private static async Task Until(Func<bool> condition, int seconds = 30)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(50);
        }
    }

    private static async Task Post(string url, string path, object body)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");
        (await http.PostAsync(url.TrimEnd('/') + path, content)).EnsureSuccessStatusCode();
    }

    private static async Task<(string Url, GatewaySession Session)?> SignInAsync()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_INSIGHTS_STATUS");
        if (path == null || !File.Exists(path)) return null;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Post(url, "/__fixture/reset", new { });
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        return (url, session);
    }

    [Fact]
    public async Task StatusLogsUsageRestartMaintenanceAndUpdate()
    {
        if (await SignInAsync() is not var (url, session)) return;
        var api = new CommandCenterApi(session);

        // The status and its platforms.
        var status = await api.StatusAsync();
        Assert.Equal("Hermes 0.21.5", status.VersionWords);
        Assert.Equal("Running", status.GatewayWords);
        Assert.Equal("3", status.SessionsWords);
        Assert.Equal(["Discord", "Slack", "Telegram"], status.Platforms.Select(p => p.Name));
        Assert.Equal("Login failed: the bot token was refused.", status.Platforms[0].Error);
        Assert.Equal("1 App Needs Attention", StatusSummary.Of(status, null, true).Words);

        // The update check.
        var check = await api.UpdateCheckAsync();
        Assert.Equal("3 Updates Available", check.Words);
        Assert.True(check.CanUpdateNow);
        Assert.Equal(3, check.Commits.Count);

        // Logs: newest last on the wire; Errors is a minimum level.
        var all = await api.LogsAsync(LogLevelFilter.All);
        Assert.Equal(200, all.Count);
        Assert.EndsWith("[500]", all[^1]);
        var errors = await api.LogsAsync(LogLevelFilter.Errors);
        Assert.NotEmpty(errors);
        Assert.All(errors, l => Assert.Equal(LogLineLevel.Error, LogLines.Level(l)));
        var warnings = await api.LogsAsync(LogLevelFilter.Warnings);
        Assert.Contains(warnings, l => LogLines.Level(l) == LogLineLevel.Error);
        Assert.Contains(warnings, l => LogLines.Level(l) == LogLineLevel.Warning);
        var logs = new CommandCenterLogsModel(api);
        await logs.ReadAsync();
        Assert.IsType<CommandCenterLogsModel.Load.Ready>(logs.State);
        Assert.EndsWith("[500]", logs.Lines[0]);

        // Usage by period.
        var week = await api.UsageAsync(7);
        Assert.Equal(7, week.PeriodDays);
        Assert.Equal(7, week.Daily.Count);
        Assert.Equal(["hermes-4", "claude-opus-5", "gemma-3-27b"], week.Models.Select(m => m.Id));
        Assert.Equal("release-notes", week.Skills[0].Id);
        Assert.False(week.IsEmpty);
        var quarter = await api.UsageAsync(90);
        Assert.Equal(90, quarter.Daily.Count);
        Assert.True(quarter.Tokens > week.Tokens);
        await Post(url, "/__fixture/actions", new { usage = "empty" });
        Assert.True((await api.UsageAsync(30)).IsEmpty);
        await Post(url, "/__fixture/reset", new { });
        await Post(url, "/__fixture/actions", new { old = true });
        var old = await api.UsageAsync(30);
        Assert.Equal("hermes-4", old.Models[0].Id);
        Assert.Equal("Hermes 0.21.5", (await api.StatusAsync()).VersionWords);
        await Post(url, "/__fixture/reset", new { });

        // Restart Gateway: the sockets really drop; the poll reads through it to "Gateway Restarted".
        var restart = new GatewayActionRun(api.Actions) { Interval = TimeSpan.FromMilliseconds(400) };
        restart.Start(() => api.Actions.RestartAsync());
        await Until(() => !restart.IsBusy, 40);
        Assert.Equal("Gateway Restarted", GatewayRestartWords.Words(restart.Phase)?.Text);
        Assert.Contains("✓ Gateway restarted", restart.Lines);

        // A restart that fails to start says the gateway's reason.
        await Post(url, "/__fixture/actions", new { restart = "fail" });
        var refused = new GatewayActionRun(api.Actions) { Interval = TimeSpan.FromMilliseconds(200) };
        refused.Start(() => api.Actions.RestartAsync());
        await Until(() => !refused.IsBusy, 20);
        Assert.Equal(new ActionPhase.Failed("Failed to restart gateway: launchctl answered 5"), refused.Phase);
        await Post(url, "/__fixture/actions", new { restart = (string?)null });

        // The maintenance actions and their output.
        foreach (var (action, ok, last) in new[]
        {
            (MaintenanceAction.Doctor, false, "Found 1 issue(s) to address."),
            (MaintenanceAction.SecurityAudit, true, "Audit finished: 0 critical, 1 note."),
            (MaintenanceAction.Backup, true, "✓ Backup written to"),
        })
        {
            var run = new GatewayActionRun(api.Actions) { Interval = TimeSpan.FromMilliseconds(300) };
            run.Start(() => action.StartAsync(api.Actions));
            await Until(() => !run.IsBusy, 30);
            var finished = Assert.IsType<ActionPhase.Finished>(run.Phase);
            Assert.Equal(ok, finished.Ok);
            Assert.StartsWith(last, finished.LastLine);
            Assert.Equal(ok ? "Finished" : "Finished with Problems", ActionWords.MaintenanceWords(run.Phase)?.Text);
        }

        // Update Hermes: checked, asked, run through the restart, confirmed from /api/status.
        await Post(url, "/__fixture/actions", new { update_seconds = 3 });
        var key = "e2e-" + Guid.NewGuid();
        var update = HermesUpdateCenter.Shared.Update(key, () => new HermesUpdate(key, "Studio", HermesUpdate.PlaceWords(true, "127.0.0.1"),
            new HermesUpdateApi(new SessionRest(session))) { PollInterval = TimeSpan.FromMilliseconds(400), VersionReadDelay = TimeSpan.FromSeconds(1) });
        await Until(() => update.Phase == HermesUpdate.PhaseKind.Asking, 30);
        Assert.Equal("0.21.5", update.From);
        Assert.Equal(3, update.Commits.Count);
        update.Confirm();
        await Until(() => update.Phase == HermesUpdate.PhaseKind.Ended, 90);
        Assert.Equal(new HermesUpdateEnd.Updated("0.22.0"), update.End);
        Assert.Equal("Updated to 0.22.0", update.Headline);
        Assert.Contains("✓ Hermes updated to 0.22.0", update.Action!.Lines);
        Assert.Equal("Up to Date", (await api.UpdateCheckAsync()).Words);
        await Post(url, "/__fixture/reset", new { });

        // A Hermes that won't update itself here: the command to run instead.
        await Post(url, "/__fixture/actions", new { update = "refused" });
        var key2 = "e2e-" + Guid.NewGuid();
        var refusedUpdate = new HermesUpdate(key2, "Studio", "here", new HermesUpdateApi(new SessionRest(session))) { PollInterval = TimeSpan.FromMilliseconds(300) };
        refusedUpdate.Check();
        await Until(() => refusedUpdate.Phase == HermesUpdate.PhaseKind.Asking, 30);
        refusedUpdate.Confirm();
        await Until(() => refusedUpdate.Phase == HermesUpdate.PhaseKind.Ended, 30);
        Assert.Equal("docker compose pull", refusedUpdate.CommandToCopy);
        await Post(url, "/__fixture/reset", new { });
    }

    [Fact]
    public async Task AFailedUpdateStopsOnTheInstall()
    {
        if (await SignInAsync() is not var (url, session)) return;
        await Post(url, "/__fixture/actions", new { update = "fail" });
        var run = new HermesUpdate("e2e-fail", "Studio", "here", new HermesUpdateApi(new SessionRest(session)))
        {
            PollInterval = TimeSpan.FromMilliseconds(300), VersionReadDelay = TimeSpan.FromMilliseconds(500),
        };
        run.Check();
        await Until(() => run.Phase == HermesUpdate.PhaseKind.Asking, 30);
        run.Confirm();
        await Until(() => run.Phase == HermesUpdate.PhaseKind.Ended, 60);
        Assert.Equal(new HermesUpdateEnd.Failed("Update failed. Nothing was changed."), run.End);
        Assert.Equal("The Update Didn’t Finish", run.Headline);
        Assert.Equal(HermesUpdateStepState.Failed, run.Steps.First(s => s.Id == HermesUpdateStepId.Install).State);
        await Post(url, "/__fixture/reset", new { });
    }
}

[CollectionDefinition("Insights status E2E", DisableParallelization = true)]
public class InsightsStatusCollection;
