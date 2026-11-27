using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Jobs;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// The Jobs words, schedule, delivery, blueprints, row edge, store rules and editor, ported from the Swift tests
/// (Tests/Pages/Job*Tests.swift) with the same inputs and the tests' zone (America/Chicago).
internal static class Chicago
{
    public static readonly TimeZoneInfo Zone = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");

    /// `new Date(y, m0, d, h, min)` in the tests' zone (month is 0-based like JS).
    public static DateTimeOffset Date(int y, int m0, int d, int h = 0, int min = 0, int s = 0) => JobClock.FromWall(y, m0 + 1, d, h, min, s, Zone)!.Value;
    public static DateTimeOffset Parse(string iso) => PagesDate.Parse(iso, Zone)!.Value;
    public static string Iso(DateTimeOffset d) => d.ToString("yyyy-MM-ddTHH:mm:ss.fffzzz");
}

public class JobWordsScheduleTests
{
    private static readonly TimeZoneInfo C = Chicago.Zone;

    [Fact]
    public void DescribesCommonCronLines()
    {
        Assert.Equal("Weekdays at 8:15 AM", JobWords.DescribeCron("15 8 * * 1-5"));
        Assert.Equal("Every day at 9:00 AM", JobWords.DescribeCron("0 9 * * *"));
        Assert.Equal("Every day at 8:00 AM and 6:00 PM", JobWords.DescribeCron("0 8,18 * * *"));
        Assert.Equal("Every Monday at 7:30 AM", JobWords.DescribeCron("30 7 * * 1"));
        Assert.Equal("Mon, Wed and Fri at 10:00 AM", JobWords.DescribeCron("0 10 * * 1,3,5"));
        Assert.Equal("Monthly on day 1 at 9:00 AM", JobWords.DescribeCron("0 9 1 * *"));
        Assert.Equal("Every 15 minutes", JobWords.DescribeCron("*/15 * * * *"));
        Assert.Equal("Every 30 minutes, 9:00 AM–5:59 PM (weekdays)", JobWords.DescribeCron("*/30 9-17 * * 1-5"));
        Assert.Equal("Every hour, on the hour", JobWords.DescribeCron("0 * * * *"));
        Assert.Equal("Every 2 hours at :05", JobWords.DescribeCron("5 */2 * * *"));
        Assert.Null(JobWords.DescribeCron("0 9 * 1 *"));
        Assert.Null(JobWords.DescribeCron("weekdays at 9am"));
    }

    [Fact]
    public void ReadsIntervalAndOneOffSchedules()
    {
        Assert.Equal("Every 30 minutes", JobWords.DescribeSchedule("every 30m", zone: C));
        Assert.Equal("Every day", JobWords.DescribeSchedule("every 1440m", zone: C));
        Assert.Equal("Every 2 hours", JobWords.DescribeSchedule("every 120m", zone: C));
        Assert.Equal("Weekdays at 8:15 AM", JobWords.DescribeSchedule("15 8 * * 1-5", zone: C));
        var now = Chicago.Date(2026, 8, 27, 10);
        Assert.Equal("Once on Wed, Sep 30 at 9:00 AM", JobWords.DescribeSchedule("once at 2026-09-30 09:00", now, C));
        var iso = JobWords.DescribeSchedule("2026-10-02T08:00:00-05:00", now, C) ?? "";
        Assert.Matches(@"^Once on \w{3}, Oct \d{1,2}(, 2026)? at \d{1,2}:\d{2} [AP]M$", iso);
        Assert.Null(JobWords.DescribeSchedule("once at 2026-13-45 09:00", now, C));
        Assert.Equal("Once on Mon, Jan 4, 2027 at 9:00 AM", JobWords.DescribeSchedule("once at 2027-01-04 09:00", now, C));
    }

    private static string WrittenAhead(string wall, int shift)
    {
        var date = wall[..10];
        var time = wall[11..];
        var p = date.Split('-').Select(int.Parse).ToArray();
        var noon = Chicago.Date(p[0], p[1] - 1, p[2], 12);
        var offset = (int)C.GetUtcOffset(noon).TotalMinutes + shift;
        var abs = Math.Abs(offset);
        return $"{date}T{time}:00{(offset < 0 ? "-" : "+")}{abs / 60:00}:{abs % 60:00}";
    }

    [Fact]
    public void SaysAWeeklyJobRunInAnotherZoneAtThePcsTime()
    {
        var next = WrittenAhead("2026-09-28T06:00", 300);
        Assert.Equal(1, JobClock.Local(Chicago.Parse(next), C).Hour);
        Assert.Equal("Every Monday at 1:00 AM", JobWords.LocalCronSchedule("0 6 * * 1", next, C));
        Assert.Equal("Every day at 1:00 AM", JobWords.LocalCronSchedule("0 6 * * *", next, C));
        Assert.Matches(@"^Weekdays at 6:00 AM UTC([+−]\d+(:\d{2})?)?$", JobWords.LocalCronSchedule("0 6 * * 1-5", next, C) ?? "");
        Assert.Null(JobWords.LocalCronSchedule("0 6 * * 1", WrittenAhead("2026-09-28T06:00", 0), C));
        Assert.Null(JobWords.LocalCronSchedule("0 6 * * 1", WrittenAhead("2026-09-28T07:00", 300), C));
        Assert.Null(JobWords.LocalCronSchedule("*/15 * * * *", WrittenAhead("2026-09-28T06:15", 300), C));
        Assert.Null(JobWords.LocalCronSchedule("0 6 * * 1", null, C));
        Assert.Null(JobWords.LocalCronSchedule("0 6 * * 1", "2026-09-28T06:00:00", C));
    }

    [Fact]
    public void PrefersAZoneFixThenAOneOffsOwnTimeThenTheSummary()
    {
        var now = Chicago.Date(2026, 8, 27, 10);
        var next = WrittenAhead("2026-09-28T06:00", 300);
        var local = JobWords.Clock(Chicago.Parse(next), C);
        Assert.Equal($"Every Monday at {local}", JobWords.JobScheduleWords("0 6 * * 1", "0 6 * * 1", "", next, "Every Monday at 6:00 AM", now, C));
        Assert.Equal("Every Monday at 6:00 AM", JobWords.JobScheduleWords("0 6 * * 1", "0 6 * * 1", "", WrittenAhead("2026-09-28T06:00", 0),
            "Every Monday at 6:00 AM", now, C));
        Assert.StartsWith("Once on Wed, Sep 30 at ", JobWords.JobScheduleWords("once at 2026-09-30 09:00", "once at 2026-09-30 09:00",
            "2026-09-30T09:00:00-05:00", "2026-09-30T09:00:00-05:00", now: now, zone: C));
        Assert.StartsWith("Once on Wed, Sep 30", JobWords.JobScheduleWords("once at 2026-09-30 09:00", "once at 2026-09-30 09:00", "", null, now: now, zone: C));
        Assert.Equal("every day at 10am", JobWords.JobScheduleWords("every day at 10am", "every day at 10am", "", null, now: now, zone: C));
    }
}

public class JobWordsNextRunTests
{
    private static readonly TimeZoneInfo C = Chicago.Zone;
    private static readonly DateTimeOffset Mon9pm = Chicago.Parse("2026-09-28T21:05:00-05:00");

    private static string Cron(string expr, string? next, string state, string words, DateTimeOffset? now = null) =>
        JobWords.JobNextWords(state, new CronSchedule { Kind = "cron", Expr = expr }, next, words, now ?? Mon9pm, C);

    private static string Every(double minutes, string next, string words) =>
        JobWords.JobNextWords("scheduled", new CronSchedule { Kind = "interval", Minutes = minutes }, next, words, Mon9pm, C);

    [Fact]
    public void NextCronFireReadsWeekdaysListsRangesAndSteps()
    {
        DateTimeOffset? Fire(string expr, DateTimeOffset after, int? offset) => JobWords.NextCronFire(expr, after, offset, C);
        Assert.Equal(Chicago.Parse("2026-09-29T13:00:00-05:00"), Fire("0 13 * * 1-5", Mon9pm, -300));
        Assert.Equal(Chicago.Parse("2026-10-04T18:00:00-05:00"), Fire("0 18 * * 0", Mon9pm, -300));
        Assert.Equal(Chicago.Parse("2026-09-29T09:00:00-05:00"), Fire("*/30 9-19 * * *", Mon9pm, -300));
        Assert.Equal(Chicago.Parse("2026-09-29T17:00:00-05:00"), Fire("0 9,13,17 * * *", Chicago.Parse("2026-09-29T13:00:00-05:00"), -300));
        Assert.Equal(Chicago.Parse("2026-10-05T13:00:00-05:00"), Fire("0 13 * * 1-5", Chicago.Parse("2026-10-02T18:00:00-05:00"), -300));
        Assert.Equal(Chicago.Parse("2026-10-04T06:00:00-05:00"), Fire("0 6 * * 7", Mon9pm, -300));
        Assert.Equal(Chicago.Parse("2026-09-29T13:00:00-07:00"), Fire("0 13 * * 1-5", Mon9pm, -420));
        Assert.Equal(Chicago.Date(2026, 8, 29, 8, 30), Fire("30 8 * * *", Chicago.Date(2026, 8, 28, 21, 5), null));
        Assert.Null(Fire("every 30m", DateTimeOffset.Now, null));
        Assert.Null(Fire("61 * * * *", DateTimeOffset.Now, null));
        Assert.Null(Fire("0 0 31 2 *", DateTimeOffset.Now, null));
    }

    [Fact]
    public void ReadsTheWrittenOffset()
    {
        Assert.Equal(-300, JobWords.WrittenOffset("2026-10-05T13:00:00-05:00"));
        Assert.Equal(0, JobWords.WrittenOffset("2026-10-05T13:00:00Z"));
        Assert.Equal(330, JobWords.WrittenOffset("2026-10-05T13:00:00+0530"));
        Assert.Null(JobWords.WrittenOffset("2026-10-05T13:00:00"));
    }

    [Fact]
    public void SkippedRunsAndDaylightSaving()
    {
        Assert.Equal("Skipped until Mon, Oct 5", Cron("0 13 * * 1-5", "2026-10-05T13:00:00-05:00", "scheduled", "Weekdays at 1:00 PM"));
        var sat = Chicago.Parse("2026-10-31T09:30:00-05:00");
        Assert.DoesNotContain("Skipped", Cron("0 9 * * *", "2026-11-01T09:00:00-06:00", "scheduled", "Daily at 9:00 AM", sat));
        Assert.StartsWith("Skipped", Cron("0 9 * * *", "2026-11-01T09:00:00-06:00", "scheduled", "Daily at 9:00 AM", Chicago.Parse("2026-10-31T08:30:00-05:00")));
        Assert.StartsWith("Skipped", Cron("0 9 * * *", "2026-11-03T09:00:00-06:00", "scheduled", "Daily at 9:00 AM", sat));
    }

    [Fact]
    public void NamesTheDayOrTheTime()
    {
        Assert.Equal("Next tomorrow", Cron("0 13 * * 1-5", "2026-09-29T13:00:00-05:00", "scheduled", "Weekdays at 1:00 PM"));
        Assert.Equal("Next Sunday", Cron("0 18 * * 0", "2026-10-04T18:00:00-05:00", "scheduled", "Every Sunday at 6:00 PM"));
        Assert.Equal("Next today", Cron("0 22 * * *", "2026-09-28T22:00:00-05:00", "scheduled", "Every day at 10:00 PM", Chicago.Parse("2026-09-28T20:00:00-05:00")));
        Assert.Equal("Next 11:11 PM", Every(360, "2026-09-28T23:11:00-05:00", "Every 6 hours"));
        Assert.Equal("Next tomorrow 5:12 AM", Every(360, "2026-09-29T05:12:00-05:00", "Every 6 hours"));
        Assert.Equal("Next tomorrow 9:00 AM", Cron("0 9,13,17 * * *", "2026-09-29T09:00:00-05:00", "scheduled", "Every day at 9:00 AM, 1:00 PM and 5:00 PM"));
        Assert.Equal("Next in 12 min", Every(30, "2026-09-28T21:17:00-05:00", "Every 30 minutes"));
        Assert.Equal("Next in 1 min", Every(30, "2026-09-28T21:05:20-05:00", "Every 30 minutes"));
        Assert.Equal("Due now", Every(30, "2026-09-28T21:04:00-05:00", "Every 30 minutes"));
        Assert.Equal("Due now", Every(30, "2026-09-28T20:51:00-05:00", "Every 30 minutes"));
        Assert.Equal("Overdue", Every(30, "2026-09-28T20:49:00-05:00", "Every 30 minutes"));
        Assert.Equal("", Cron("0 16 * * 5", "2026-10-02T16:00:00-05:00", "paused", "Every Friday at 4:00 PM"));
        Assert.Equal("", JobWords.JobNextWords("scheduled", new CronSchedule { Kind = "once" }, "2026-10-02T08:00:00-05:00",
            "Once on Fri, Oct 2 at 8:00 AM", Mon9pm, C));
        Assert.Equal("", Cron("0 9 * * *", null, "scheduled", "Every day at 9:00 AM"));
        Assert.Equal("Next Thu, Oct 1", Cron("0 6 1 * *", "2026-10-01T06:00:00-05:00", "scheduled", "Monthly on day 1 at 6:00 AM",
            Chicago.Parse("2026-09-20T12:00:00-05:00")));
        Assert.Equal("Next Tue, Oct 6, 6:00 AM", Every(20160, "2026-10-06T06:00:00-05:00", "Every 14 days"));
    }
}

public class JobWordsLabelTests
{
    private static readonly TimeZoneInfo C = Chicago.Zone;

    [Fact]
    public void RunLabels()
    {
        Assert.Equal("", JobWords.RunPreview("[IMPORTANT: You are running as a scheduled cron job. DELIVER..."));
        Assert.Equal("Morning note sent", JobWords.RunPreview("[IMPORTANT: quiet] Morning note sent"));
        var run = new CronRun("r1") { StartedAt = Chicago.Parse("2026-06-01T15:17:00Z").ToUnixTimeSeconds(), MessageCount = 4, Title = "[IMPORTANT: You are running as a sch…" };
        var label = JobWords.CronRunLabel(run, C);
        Assert.Equal("Mon, Jun 1, 10:17 AM", label.Title);
        Assert.Equal("4 messages", label.Detail);
        var weekly = new CronRun("r2") { StartedAt = 1, MessageCount = 6, Title = "alex-weekly-review · Sep 20 18:00", Preview = "Weekly review sent" };
        Assert.Equal("6 messages · Weekly review sent", JobWords.CronRunLabel(weekly, C).Detail);
        weekly.Preview = null;
        Assert.Equal("6 messages", JobWords.CronRunLabel(weekly, C).Detail);

        var doc = new CronRun("cron_output:j-script:2026-10-09_08-00-00") { Source = "cron_output", Title = "COMPLETED · Disk 71% used" };
        Assert.Equal("Completed", JobWords.CronRunLabel(doc, C).Detail);
        Assert.Equal(new RunOpens.Document("2026-10-09_08-00-00"), doc.Opens);
        var exec = new CronRun("cron_output:j-script:exec:3") { Source = "cron_output", Title = "FAILED · PermissionError: Permission denied" };
        Assert.Equal("Failed · Permission denied", JobWords.CronRunLabel(exec, C).Detail);
        Assert.IsType<RunOpens.Nothing>(exec.Opens);
        Assert.IsType<RunOpens.Nothing>(new CronRun("cron_output:j-script:latest") { Source = "cron_output" }.Opens);
        Assert.IsType<RunOpens.Chat>(new CronRun("cron_j_20261009_080000").Opens);
        Assert.Equal("Failed", JobWords.CronRunLabel(new CronRun("cron_output:x:y") { Source = "cron_output", Title = "# Cron Job: x (FAILED)" }, C).Detail);
    }

    [Fact]
    public void SaysWhereAJobDeliversInWords()
    {
        var dm = new CronOrigin { Platform = "telegram", ChatId = "100000001", ChatName = "Alex Rivera", ThreadId = "None" };
        var group = new CronOrigin { Platform = "telegram", ChatId = "-1003745705383", ChatName = "Hermes Projects", ThreadId = "13822" };
        var labels = new Dictionary<string, string> { ["local"] = "Keep in Hermes (no message)", ["telegram"] = "Telegram" };
        Assert.Equal("Where it was created · Telegram · Alex Rivera", JobWords.HumanDeliver("origin", dm, labels));
        Assert.Equal("Where it was created", JobWords.HumanDeliver("origin", null, labels));
        Assert.Equal("Telegram · Hermes Projects (topic 28549)", JobWords.HumanDeliver("telegram:-1003745705383:28549", group, labels));
        Assert.Equal("Telegram · group …7489 (topic 24)", JobWords.HumanDeliver("telegram:-1003994007489:24", dm, labels));
        Assert.Equal("Telegram · chat 555", JobWords.HumanDeliver("telegram:555", null, labels));
        Assert.Equal("Email · ops@example.com", JobWords.HumanDeliver("email:ops@example.com", null, labels));
        Assert.Equal("Telegram · group …1111 + Telegram · group …2222", JobWords.HumanDeliver("telegram:-1001111111111,telegram:-1002222222222", dm, labels));
        Assert.Equal("Telegram · group 1111111111 + Telegram · group 9999991111", JobWords.HumanDeliver("telegram:-1001111111111,telegram:-1009999991111", dm, labels));
        Assert.Equal("Telegram", JobWords.HumanDeliver("telegram", dm, labels));
        Assert.Equal("Keep in Hermes (no message)", JobWords.HumanDeliver("local", dm, labels));
        Assert.Equal("Telegram", JobWords.HumanDeliver("local,telegram", dm, labels));
        Assert.Equal("Keep in Hermes (no message)", JobWords.HumanDeliver(""));
        Assert.Equal("Home Assistant", JobWords.HumanDeliverTarget("homeassistant"));
        Assert.Equal("GroupMe · chat …2345", JobWords.HumanDeliverTarget("groupme:12345"));
        Assert.Equal("My Bridge", JobWords.HumanDeliverTarget("my_bridge"));

        var a = new CronJob("a") { Origin = new CronOrigin { Platform = "telegram", ChatId = "-1003791915383", ChatName = "Hermes Projects", ThreadId = "28549" } };
        var names = JobWords.KnownChatNames([a, new CronJob("b"), new CronJob("c")]);
        Assert.Equal(new Dictionary<string, string> { ["telegram:-1003791915383"] = "Hermes Projects" }, names);
        Assert.Equal("Telegram · Hermes Projects (topic 28549)", JobWords.HumanDeliver("telegram:-1003791915383:28549", names: names));
        Assert.Equal("Telegram · group …5383 (topic 28549)", JobWords.HumanDeliver("telegram:-1003791915383:28549"));

        Assert.Equal("Bot Chat (Maple Revenue Operator)", JobWords.ReadableTargetName("Bot Chat (maple-revenue-operator)"));
        Assert.Equal("Bot Chat (Ivy the Scheduler)", JobWords.ReadableTargetName("Bot Chat (ivy)", new Dictionary<string, string> { ["ivy"] = "Ivy the Scheduler" }));
        Assert.Equal("Bot Chat (Hermes)", JobWords.ReadableTargetName("Bot Chat (default)"));
    }

    [Fact]
    public void SaysOneTimeTheSameWayOnEveryPage()
    {
        var now = Chicago.Date(2026, 8, 27, 10);
        string Say(DateTimeOffset? d) => JobWords.RelativeDateTime(d, now, C);
        Assert.Equal("Today at 9:05 AM", Say(Chicago.Date(2026, 8, 27, 9, 5)));
        Assert.Equal("Yesterday at 4:07 PM", Say(Chicago.Date(2026, 8, 26, 16, 7)));
        Assert.Equal("Tomorrow at 6:00 AM", Say(Chicago.Date(2026, 8, 28, 6, 0)));
        Assert.Equal("Wed at 6:01 AM", Say(Chicago.Date(2026, 8, 23, 6, 1)));
        Assert.Equal("Thu at 6:00 AM", Say(Chicago.Date(2026, 9, 1, 6, 0)));
        Assert.Equal("Sep 12 at 4:07 PM", Say(Chicago.Date(2026, 8, 12, 16, 7)));
        Assert.Equal("Dec 31, 2025 at 11:00 PM", Say(Chicago.Date(2025, 11, 31, 23, 0)));
        Assert.Equal("", Say(null));
        Assert.Equal("", JobWords.RelativeDateTime("soon", now, C));
    }

    [Fact]
    public void AsksBeforeRunNow()
    {
        var labels = new Dictionary<string, string> { ["local"] = "Run History Only", ["telegram"] = "Telegram" };
        var local = JobWords.RunNowCopy("Weekly review", "local", labels: labels);
        Assert.Equal("Run “Weekly review” now?", local.Title);
        Assert.Equal("Its result is kept in its Run History. Its schedule does not change.", local.Description);
        Assert.Equal("Run “Weekly review” Now?", JobWords.RunAlertTitle(local.Title));
        Assert.Equal("It delivers to Alex Rivera on Telegram. Its schedule does not change.",
            JobWords.RunNowCopy("Weekly review", "origin", new CronOrigin { Platform = "telegram", ChatId = "42", ChatName = "Alex Rivera" }, labels).Description);
        Assert.Equal("It delivers to Telegram and Ops on Discord. Its schedule does not change.",
            JobWords.RunNowCopy("Digest", "telegram,discord:-1001234567890", labels: labels, names: new Dictionary<string, string> { ["discord:-1001234567890"] = "Ops" }).Description);
        Assert.Equal("It delivers to the chat it came from. Its schedule does not change.", JobWords.RunNowCopy("Digest", "origin", labels: labels).Description);
    }

    [Fact]
    public void TitlesErrorsAndState()
    {
        var casing = JobWords.KnownWordCasing(["GBrain automatic updater", "Daily NHB+ new call notes publisher", "FLOP testnet launch watcher",
            "gbrain-daily-update-check-local"]);
        Assert.Equal("Alex midday filtered alert", JobWords.HumanJobTitle("alex-midday-filtered-alert"));
        Assert.Equal("GBrain daily update check local", JobWords.HumanJobTitle("gbrain-daily-update-check-local", casing));
        Assert.Equal("iOS build PR watch", JobWords.HumanJobTitle("ios_build_pr_watch"));
        Assert.Equal("NHB weekly sync", JobWords.HumanJobTitle("nhb-weekly-sync", casing));
        Assert.Equal("backup", JobWords.HumanJobTitle("backup"));
        Assert.Equal("KPI-Weekly", JobWords.HumanJobTitle("KPI-Weekly"));

        Assert.True(JobWords.JobIsScriptOnly(new CronJob("s") { NoAgent = true, Script = "echo hi" }));
        Assert.False(JobWords.JobIsScriptOnly(new CronJob("s") { NoAgent = true, Script = "" }));
        const string raw = "RuntimeError: Cron job 'x' has no model configured (job.model=None, HERMES_MODEL=''). Set a per-job model via `hermes cron edit x --model <name>`.";
        Assert.Equal("No model is set for this job. Choose one in Edit Job.", JobWords.LastErrorSummary(raw));
        Assert.Equal("bad schedule", JobWords.LastErrorSummary("[blocked_config:silent] ⚠️ ValueError: bad schedule\nDetails follow"));
        var longer = JobWords.LastErrorSummary("HTTPStatusError: " + new string('x', 400));
        Assert.True(longer.Length <= 200 && longer.EndsWith('…'));
        Assert.Equal("", JobWords.LastErrorSummary(null));

        var job = new CronJob("j");
        Assert.Equal("scheduled", JobWords.JobState(job));
        job.Enabled = false;
        Assert.Equal("disabled", JobWords.JobState(job));
        job.State = "paused";
        Assert.Equal("paused", JobWords.JobState(job));
        Assert.Equal("j", JobWords.JobTitle(job));
        job.Prompt = new string('a', 70);
        Assert.Equal(new string('a', 60) + "…", JobWords.JobTitle(job));
        var failed = new CronJob("f") { LastStatus = "error" };
        Assert.True(JobWords.LastRunFailed(failed));
        failed.State = "paused";
        Assert.False(JobWords.LastRunFailed(failed));
        var ran = new CronJob("r") { LastRunAt = "2026-09-27T09:05:00-05:00", LastStatus = "ok" };
        Assert.Equal("Last ran today at 9:05 AM · OK", JobWords.LastRunNote(ran, Chicago.Date(2026, 8, 27, 10), C));
        ran.LastError = "boom";
        Assert.Equal("Last ran yesterday at 9:05 AM · Failed", JobWords.LastRunNote(ran, Chicago.Date(2026, 8, 28, 10), C));
    }

    [Fact]
    public void SectionsAndRunningRules()
    {
        Assert.Equal(JobSection.Completed, JobWords.JobSectionFor("completed", TimeSpan.FromSeconds(1000), true));
        Assert.Equal(JobSection.Paused, JobWords.JobSectionFor("paused", TimeSpan.FromSeconds(1000), true));
        Assert.Equal(JobSection.Paused, JobWords.JobSectionFor("disabled", null, false));
        Assert.Equal(JobSection.Running, JobWords.JobSectionFor("running", TimeSpan.FromSeconds(1000), true));
        Assert.Equal(JobSection.NeedsAttention, JobWords.JobSectionFor("error", null, false));
        Assert.Equal(JobSection.NeedsAttention, JobWords.JobSectionFor("scheduled", null, true));
        Assert.Equal(JobSection.Scheduled, JobWords.JobSectionFor("scheduled", null, false));

        var now = DateTimeOffset.Now;
        var late = new CronJob("late") { NextRunAt = Chicago.Iso(now.AddMinutes(-14)) };
        Assert.Null(JobWords.NextRunOverdue(late, now));
        late.NextRunAt = Chicago.Iso(now.AddMinutes(-20));
        Assert.NotNull(JobWords.NextRunOverdue(late, now));
        Assert.Equal(JobSection.NeedsAttention, JobWords.Section(late, now));
        Assert.Equal("Overdue", JobWords.StatusWord(late, now));

        var job = CronJob.Parse(JsonNode.Parse("""
            {"id":"r1","name":"midday-alert","enabled":true,"state":"scheduled",
             "schedule":{"kind":"cron","expr":"0 13 * * 1-5"},"next_run_at":"2026-10-26T13:00:00-05:00",
             "last_run_at":"2026-10-24T13:00:41.502113-05:00","last_status":"error","last_error":"RuntimeError: boom",
             "latest_execution":{"id":"e9","status":"running","claimed_at":"2026-10-25T13:00:00.031870-05:00"}}
            """))!;
        Assert.True(JobWords.RunIsOut(job));
        Assert.Equal("running", JobWords.JobState(job));
        Assert.Equal(JobSection.Running, JobWords.Section(job));
        Assert.Equal("Running", JobWords.StatusWord(job));
        Assert.Equal(JobWords.ScheduleWords(job), JobWords.RowSubtitle(job));
        job.LatestRunStatus = "claimed";
        job.LastRunAt = "2026-10-25T13:04:10-05:00";
        Assert.False(JobWords.RunIsOut(job));
        job.LastRunAt = null;
        Assert.True(JobWords.RunIsOut(job));
        job.LatestRunStatus = "running";
        job.Enabled = false;
        job.State = "paused";
        Assert.Equal(JobSection.Paused, JobWords.Section(job));
        Assert.True(JobWords.IsRunning(job) && JobWords.IsPaused(job));

        var bot = new CronJob("b1") { Enabled = true, State = "scheduled", BotWorking = "queued" };
        Assert.True(JobWords.WorkIsOut(bot) && !JobWords.RunIsOut(bot));
        Assert.Equal(JobSection.Running, JobWords.Section(bot));
    }

    [Fact]
    public void DecodesTheGatewaysJobRecord()
    {
        var job = CronJob.Parse(JsonNode.Parse("""
            {"id":"a1b2c3","name":"alex-midday-filtered-alert","prompt":"…","skills":[],"script":null,"no_agent":false,
             "schedule":{"kind":"cron","expr":"0 13 * * 1-5","display":"0 13 * * 1-5"},"enabled":true,"state":"scheduled",
             "deliver":"origin","origin":{"platform":"telegram","chat_id":100000001,"chat_name":"Alex Rivera","thread_id":null},
             "profile":"inbox","profile_name":"inbox","hermes_home":"/Users/x/.hermes/profiles/inbox"}
            """))!;
        Assert.Equal("inbox|a1b2c3", job.Key);
        Assert.Equal("100000001", job.Origin?.ChatId);
        Assert.Equal("Where it was created · Telegram · Alex Rivera", JobWords.HumanDeliver(job.Deliver ?? "", job.Origin));
        Assert.Equal("inbox", CronJob.Parse(JsonNode.Parse("""{"id":"j1","profile":"inbox"}"""))!.Owner);
        // The cache's shape reads back as the same job.
        Assert.Equal(job, CronJob.Parse(job.ToJson()));
    }
}

public class JobRowEdgeTests
{
    private static CronJob Job(string? state = null, string? next = "2026-09-27T10:04:00-05:00") =>
        new("j") { State = state, Schedule = new CronSchedule { Kind = "interval", Display = "Every 30 minutes", Minutes = 30 }, NextRunAt = next };

    private static RowEdge? Edge(CronJob job, DateTimeOffset now, bool running = false) => JobWords.Edge(job, now, Chicago.Zone, running);

    [Fact]
    public void TheEdgeSaysWhen()
    {
        Assert.Equal("in 12 min", Edge(Job(), Chicago.Date(2026, 8, 27, 9, 52))?.Text);
        Assert.Equal("10:04 AM", Edge(Job(), Chicago.Date(2026, 8, 27, 7))?.Text);
        Assert.Equal("Tomorrow", Edge(Job(), Chicago.Date(2026, 8, 26, 12))?.Text);
        Assert.Equal("Sun", Edge(Job(), Chicago.Date(2026, 8, 23, 12))?.Text);
        Assert.Equal("Sep 27", Edge(Job(), Chicago.Date(2026, 8, 1, 12))?.Text);
        Assert.Equal("Sep 27, 2026", Edge(Job(), Chicago.Date(2025, 8, 1, 12))?.Text);
        Assert.Equal("next today at 10:04 AM", Edge(Job(), Chicago.Date(2026, 8, 27, 7))?.Spoken);
        Assert.Equal("Now", Edge(Job(), Chicago.Date(2026, 8, 27, 10, 9))?.Text);
        var late = Edge(Job(), Chicago.Date(2026, 8, 27, 12, 4));
        Assert.Equal(("2h late", EdgeTone.Late, "2 hours late"), (late?.Text, late?.Tone ?? EdgeTone.Plain, late?.Spoken));
        Assert.Equal("30m late", Edge(Job(), Chicago.Date(2026, 8, 27, 10, 34))?.Text);
        Assert.Equal("3d late", Edge(Job(), Chicago.Date(2026, 8, 30, 10, 4))?.Text);
        var running = Job() with { LatestRunClaimedAt = "2026-09-27T10:00:00-05:00" };
        Assert.Equal("4m so far", Edge(running, Chicago.Date(2026, 8, 27, 10, 4), true)?.Text);
        Assert.Null(Edge(Job(), Chicago.Date(2026, 8, 27, 10, 4), true));
        Assert.Null(Edge(running, Chicago.Date(2026, 8, 29, 10, 4), true));
        Assert.Null(Edge(Job("paused"), Chicago.Date(2026, 8, 26, 12)));
        var done = Job("completed") with { LastRunAt = "2026-09-26T09:00:00-05:00" };
        Assert.Equal("Yesterday", Edge(done, Chicago.Date(2026, 8, 27, 12))?.Text);
        Assert.Equal(JobWords.ScheduleWords(Job(), Chicago.Date(2026, 8, 26, 12), Chicago.Zone), JobWords.RowSchedule(Job(), Chicago.Date(2026, 8, 26, 12), Chicago.Zone));
        Assert.Equal(["1m", "59m", "1h", "47h", "3d"], new[] { 20.0, 59 * 60, 3600, 47 * 3600, 72 * 3600 }.Select(JobWords.ShortSpan));
    }
}

public class JobScheduleTests
{
    [Fact]
    public void PresetsRoundTripAndOddLinesStayCustom()
    {
        foreach (var f in JobFrequencies.All.Where(f => f != JobFrequency.Custom)) Assert.Equal(f, JobSchedule.Frequency(f.PresetExpr()!));
        Assert.Equal(["Daily", "Weekdays", "Weekly", "Monthly", "Hourly", "Every 15 minutes", "Custom"], JobFrequencies.All.Select(f => f.Title()));
        Assert.Equal(JobFrequency.Daily, JobSchedule.Frequency("15 7 * * *"));
        Assert.Equal(JobFrequency.Weekly, JobSchedule.Frequency("0 9 * * 7"));
        Assert.Equal(JobFrequency.Monthly, JobSchedule.Frequency("0 6 31 * *"));
        Assert.Equal(JobFrequency.Hourly, JobSchedule.Frequency("25 * * * *"));
        Assert.Equal(JobFrequency.Daily, JobSchedule.Frequency("  0   9 * *   * "));
        Assert.Equal(JobFrequency.Weekly, JobSchedule.Frequency("0 7 * * 5,1,3,7"));
        foreach (var odd in new[] { "0 9 * * 1-3", "*/10 * * * *", "0 9-17 * * *", "0 6,18 * * *", "0 9 1 1 *", "0 9 1 * 1", "every 30m",
                     "weekdays at 9am", "", "0 9 * * * *", "@daily", "0 25 * * *", "61 9 * * *", "0 9 32 * *", "75 * * * *", "0 7 * * 1,8" })
            Assert.Equal(JobFrequency.Custom, JobSchedule.Frequency(odd));
    }

    [Fact]
    public void FieldsComposeAndSwitches()
    {
        Assert.Equal(new JobTimeFields(18, 30, 3, 1), JobSchedule.Fields("30 18 * * 3"));
        Assert.Equal(0, JobSchedule.Fields("0 9 * * 7").Weekday);
        Assert.Equal(new JobTimeFields(), JobSchedule.Fields("99 25 40 * 9"));
        Assert.Equal([0, 1, 3, 5], JobSchedule.Fields("0 7 * * 5,1,3,7").Weekdays);
        var fields = new JobTimeFields(18, 30, 3, 31);
        Assert.Equal("30 18 * * *", JobSchedule.Compose(JobFrequency.Daily, fields));
        Assert.Equal("30 18 * * 1-5", JobSchedule.Compose(JobFrequency.Weekdays, fields));
        Assert.Equal("30 18 * * 3", JobSchedule.Compose(JobFrequency.Weekly, fields));
        Assert.Equal("30 18 31 * *", JobSchedule.Compose(JobFrequency.Monthly, fields));
        Assert.Equal("30 * * * *", JobSchedule.Compose(JobFrequency.Hourly, fields));
        Assert.Equal("0 7 * * 1,3,5", JobSchedule.Compose(JobFrequency.Weekly, new JobTimeFields(7, 0, [5, 1, 3])));
        Assert.Equal("15 7 * * 1", JobSchedule.Expression(JobFrequency.Weekly, "15 7 * * *"));
        Assert.Equal("15 7 1 * *", JobSchedule.Expression(JobFrequency.Monthly, "15 7 * * 3"));
        Assert.Equal("25 * * * *", JobSchedule.Expression(JobFrequency.Hourly, "25 7 * * *"));
        Assert.Equal("*/15 * * * *", JobSchedule.Expression(JobFrequency.Every15, "15 7 * * *"));
        Assert.Equal("15 7 * * *", JobSchedule.Expression(JobFrequency.Custom, "15 7 * * *"));
        Assert.Equal("0 9 * * *", JobSchedule.Expression(JobFrequency.Daily, "every 30m"));
        Assert.Equal("0 9 * * 1", JobSchedule.Expression(JobFrequency.Weekly, "0 9 * * 1-5"));
        Assert.Equal([1], new JobTimeFields(9, 0, Array.Empty<int>()).Weekdays);
    }

    [Fact]
    public void SummariesNotesAndCleaning()
    {
        Assert.Equal("Every day at 9:00 AM", JobSchedule.Summary(JobFrequency.Daily, "0 9 * * *"));
        Assert.Equal("Every day at 09:00", JobSchedule.Summary(JobFrequency.Daily, "0 9 * * *", true));
        Assert.Equal("Weekdays at 12:05 AM", JobSchedule.Summary(JobFrequency.Weekdays, "5 0 * * 1-5"));
        Assert.Equal("Every Wednesday at 6:30 PM", JobSchedule.Summary(JobFrequency.Weekly, "30 18 * * 3"));
        Assert.Equal("Monthly on day 31 at 9:00 AM", JobSchedule.Summary(JobFrequency.Monthly, "0 9 31 * *"));
        Assert.Equal("At the top of every hour", JobSchedule.Summary(JobFrequency.Hourly, "0 * * * *"));
        Assert.Equal("Every hour at :05", JobSchedule.Summary(JobFrequency.Hourly, "5 * * * *"));
        Assert.Equal("Every Mon, Wed and Fri at 7:00 AM", JobSchedule.Summary(JobFrequency.Weekly, "0 7 * * 1,3,5"));
        Assert.Equal("Weekends at 7:00 AM", JobSchedule.Summary(JobFrequency.Weekly, "0 7 * * 0,6"));
        Assert.Equal("Every Tue and Sun at 7:00 AM", JobSchedule.Summary(JobFrequency.Weekly, "0 7 * * 0,2"));
        Assert.Equal("", JobSchedule.Summary(JobFrequency.Custom, "0 9 * * *"));
        Assert.Equal("Months without day 31 skip this run.", JobSchedule.SkipNote(JobFrequency.Monthly, new JobTimeFields(day: 31)));
        Assert.Null(JobSchedule.SkipNote(JobFrequency.Monthly, new JobTimeFields(day: 28)));
        Assert.Equal([0, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55], JobSchedule.MinuteChoices(7));
        Assert.Equal("0 9 * * 1-5", JobSchedule.CleanCustom("  0 9 * * 1-5 \n"));
        Assert.Equal("0 9 * * 1-5", JobSchedule.CleanCustom("0\t9\n* * 1–5"));
        Assert.Equal("\"every 2h\"", JobSchedule.CleanCustom("“every 2h”"));
        Assert.Equal("0 9 * * *", JobSchedule.CleanCustom("０ ９ * * *"));
        Assert.Equal("", JobSchedule.CleanCustom(" \n\t "));
        Assert.Null(JobSchedule.CustomPreview("every 2h"));
        Assert.Equal(JobWords.DescribeCron("0 9 * * 1-5"), JobSchedule.CustomPreview("0 9 * * 1-5"));
        Assert.Equal("Times follow the clock on the computer running Hermes.", JobSchedule.ClockNote);
    }

    [Fact]
    public void NextRunFollowsTheGatewaysClock()
    {
        var now = PagesDate.Parse("2026-10-31T04:50:00-05:00")!.Value;
        var monday = JobSchedule.NextRun("0 7 * * 1,3,5", null, now, Chicago.Zone)!.Value;
        Assert.Equal("Mon at 7:00 AM", JobWords.RelativeDateTime(monday, now, Chicago.Zone));
        var utc = JobSchedule.NextRun("0 7 * * 1,3,5", 0, now, Chicago.Zone)!.Value;
        Assert.Equal("Mon at 1:00 AM", JobWords.RelativeDateTime(utc, now, Chicago.Zone));
        Assert.Null(JobSchedule.NextRun("every 2h", null, now, Chicago.Zone));
    }
}

public class JobDeliveryTests
{
    private static readonly List<DeliveryTarget> Targets = DeliveryTarget.List(JsonNode.Parse("""
        {"targets":[{"id":"local","name":"Local (save only)","home_target_set":true},
          {"id":"telegram","name":"Telegram","home_target_set":true,"home_env_var":"TELEGRAM_HOME_CHANNEL"},
          {"id":"discord","name":"Discord","home_target_set":false},
          {"id":"bot-chat:default","name":"Bot Chat (default)"},{"id":"bot-chat:research","name":"Bot Chat (research)"}]}
        """));
    private static readonly Dictionary<string, string> Bots = new() { ["default"] = "Hermes", ["research"] = "Research" };

    [Fact]
    public void ParseToggleAndPick()
    {
        Assert.Equal(["local"], JobDelivery.Parse(" , ,"));
        Assert.Equal(["local", "telegram"], JobDelivery.Parse("local,local,,telegram"));
        Assert.Equal("local,telegram", JobDelivery.Toggle("local", "telegram", true));
        Assert.Equal("telegram", JobDelivery.Toggle("local,telegram", "local", false));
        Assert.Equal("local", JobDelivery.Toggle("local", "local", false));
        Assert.True(JobDelivery.Same("local,telegram", "local, telegram,local"));
        Assert.Equal("telegram", JobDelivery.Pick("local", "telegram"));
        Assert.Equal("telegram,bot-chat:inbox", JobDelivery.Pick("telegram", "bot-chat:inbox"));
        Assert.Equal("local", JobDelivery.Pick("telegram", "telegram"));
        Assert.Equal("local", JobDelivery.Pick("telegram,discord", "local"));
        Assert.Equal("telegram,discord", JobDelivery.Pick("local,telegram", "discord"));
    }

    [Fact]
    public void LenientTargetsAndRows()
    {
        var list = DeliveryTarget.List(JsonNode.Parse("""
            {"targets":[{"name":"no id"},{"id":"x"},{"id":"x","name":"again"},{"id":"slack","home_target_set":"false"},
              {"id":"email","home_target_set":0},{"id":"sms","home_target_set":"yes"},"junk",4]}
            """));
        Assert.Equal(["x", "slack", "email", "sms"], list.Select(t => t.Id));
        Assert.Equal([true, false, false, true], list.Select(t => t.HomeTargetSet));
        var rows = JobDelivery.Rows(Targets, "local", botNames: Bots);
        Assert.Equal(["Run History Only", "Telegram", "Discord", "Bot Chat (Hermes)", "Bot Chat (Research)"], rows.Select(r => r.Title));
        Assert.True(rows[2].Note == "Set a home channel first" && !rows[2].Selectable);
        Assert.Equal(["local"], JobDelivery.Rows([], "").Select(r => r.Id));
        var origin = new CronOrigin { Platform = "telegram", ChatId = "-100123", ChatName = "Family" };
        var kept = JobDelivery.Rows(Targets, "telegram:-100123:7", origin, botNames: Bots);
        Assert.Equal(("telegram:-100123:7", "Telegram · Family (topic 7)", true), (kept[^1].Id, kept[^1].Title, kept[^1].Checked));
        Assert.DoesNotContain(JobDelivery.Rows(Targets, "discord:99", botNames: Bots), r => r.Id == "discord");
        var groups = JobDelivery.Groups(JobDelivery.Rows(Targets, "local", botNames: Bots));
        Assert.Equal(["local", "telegram"], groups.Places.Select(r => r.Id));
        Assert.Equal(["bot-chat:default", "bot-chat:research"], groups.Bots.Select(r => r.Id));
        Assert.Equal(["Discord"], groups.NeedsHome);
        Assert.Equal("Discord and Slack need a home channel first: send /sethome in the chat that should get results.", JobDelivery.NeedsHomeNote(["Discord", "Slack"]));
        var shown = JobDelivery.HistoryOnlyBeside(JobDelivery.Rows(Targets, "local,telegram"));
        Assert.Equal(["telegram"], shown.Where(r => r.Checked).Select(r => r.Id));
        Assert.Equal("Bot Chat (Maple Revenue Operator)", JobDelivery.Title(new DeliveryTarget("bot-chat:maple-revenue-operator", "Bot Chat (maple-revenue-operator)"), new Dictionary<string, string>()));
        Assert.Equal("Run History Only", JobWords.HumanDeliver("local", labels: JobDelivery.Labels));
    }
}

public class JobBlueprintTests
{
    private static readonly JsonNode Catalog = JsonNode.Parse("""
        {"blueprints":[
          {"key":"morning-brief","title":"Morning briefing","description":"A short daily briefing.","fields":[
            {"name":"time","type":"time","label":"What time?","default":"08:00","help":"24h local time, e.g. 08:00"},
            {"name":"deliver","type":"enum","label":"Where to deliver?","default":"origin","options":["origin","local","telegram"],"strict":false}]},
          {"key":"price-watch","title":"Price & availability watch","fields":[
            {"name":"item","type":"text","label":"What exactly to watch?","default":"a product URL or exact flight/hotel/listing description",
             "help":"URL or precise description — variant, dates, seller"},
            {"name":"condition","type":"text","label":"Alert me when…","default":"the all-in price drops below my target"},
            {"name":"interval_h","type":"enum","label":"How often?","default":"6","options":["1","3","6","12","24"],
             "help":"hours between checks — be gentle with rate limits"},
            {"name":"note","type":"text","optional":true}]}]}
        """)!;

    [Fact]
    public void DecodesFirstValuesAndWords()
    {
        var list = Blueprint.List(Catalog);
        Assert.Equal(["morning-brief", "price-watch"], list.Select(b => b.Key));
        Assert.True(list[1].Fields[3].Optional && list[1].Fields[3].Title == "Note");
        Assert.Equal(new Dictionary<string, string> { ["time"] = "08:00", ["deliver"] = "local" }, JobBlueprints.InitialValues(list[0]));
        var watch = JobBlueprints.InitialValues(list[1]);
        Assert.Equal("", watch["item"]);
        Assert.Equal("the all-in price drops below my target", watch["condition"]);
        Assert.Equal("Times follow the clock on the computer running Hermes.", JobBlueprints.FieldHelp(list[0].Fields[0]));
        Assert.Null(JobBlueprints.FieldHelp(list[0].Fields[1]));
        Assert.Equal("Hours between checks — be gentle with rate limits", JobBlueprints.FieldHelp(list[1].Fields[2]));
        Assert.Equal("Alert me when…", JobBlueprints.Placeholder(list[1].Fields[1]));
        Assert.Equal(["Every day", "Weekdays", "Weekends"], new[] { "everyday", "weekdays", "weekends" }.Select(o => JobBlueprints.OptionLabel(new BlueprintField("recurrence", "weekdays"), o)));
        Assert.Equal(["12 AM", "7 AM", "12 PM", "5 PM", "11 PM"], new[] { "0", "7", "12", "17", "23" }.Select(o => JobBlueprints.OptionLabel(new BlueprintField("start_hour", "enum"), o)));
        Assert.Equal(["Every hour", "Every 6 hours", "Once a day"], new[] { "1", "6", "24" }.Select(o => JobBlueprints.OptionLabel(new BlueprintField("interval_h", "enum"), o)));
        Assert.Equal("Sunday", JobBlueprints.OptionLabel(new BlueprintField("day", "enum"), "sunday"));
        Assert.Equal("Friendly", JobBlueprints.OptionLabel(new BlueprintField("tone"), "friendly"));
        Assert.Equal("time", JobBlueprints.FieldNamed("invalid time '25:00' — use HH:MM (24h)", list[0]));
        Assert.Equal("deliver", JobBlueprints.FieldNamed("deliver='fax' not allowed — one of origin, local", list[0]));
        Assert.Equal("missing required value: time (What time?)", JobBlueprints.CleanFieldError("422: missing required value: time (What time?)"));
        Assert.True(JobBlueprints.IsIncomplete(list[1], JobBlueprints.InitialValues(list[1])));
    }

    [Fact]
    public void AMalformedCatalogIsNeverFatal()
    {
        var list = Blueprint.List(JsonNode.Parse("""
            {"blueprints":["junk",7,{"title":"no key"},{"key":""},{"key":"bare"},{"key":"bare","title":"twice"},
              {"key":"fields","fields":[{"label":"no name"},{"name":"x"},{"name":"x"},3,{"name":"pick","type":"enum"},{"name":"odd","type":"colour","default":4}]}]}
            """));
        Assert.Equal(["bare", "fields"], list.Select(b => b.Key));
        Assert.Equal("Bare", list[0].Title);
        Assert.Equal(["x", "pick", "odd"], list[1].Fields.Select(f => f.Name));
        Assert.Equal(BlueprintControl.Text, JobBlueprints.Control(list[1].Fields[1]));
        Assert.Empty(Blueprint.List(null));
    }
}

/// The store's rules and the editor model, against a scripted gateway.
public class JobsStoreAndEditorTests
{
    private sealed class FakeApi() : JobsApi(null!)
    {
        public List<(string Method, string Path, string? Body)> Calls { get; } = [];
        public Func<HttpMethod, string, JsonNode?, JsonNode?> Answer { get; set; } = (_, _, _) => null;

        public override Task<JsonNode?> SendAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            lock (Calls) Calls.Add((method.Method, path, body?.ToJsonString()));
            return Task.FromResult(Answer(method, path, body));
        }
    }

    [Fact]
    public void DueReadsAndBackstops()
    {
        var now = DateTimeOffset.Now;
        var soon = new CronJob("a") { NextRunAt = Chicago.Iso(now.AddSeconds(30)) };
        Assert.Equal(33, JobsStore.NextDueRead([soon], now)!.Value, 0);
        var passed = new CronJob("b") { NextRunAt = Chicago.Iso(now.AddSeconds(-20)) };
        Assert.Equal(20, JobsStore.NextDueRead([passed], now)!.Value, 0);
        Assert.Equal(40, JobsStore.NextDueRead([passed], now, onScreen: false)!.Value, 0);
        Assert.Null(JobsStore.NextDueRead([new CronJob("c") { NextRunAt = Chicago.Iso(now.AddSeconds(-200)) }], now));
        Assert.Null(JobsStore.NextDueRead([soon with { State = "paused" }], now));
        Assert.Equal(TimeSpan.FromSeconds(300), JobsStore.BackstopGap(true, false, true));
        Assert.Equal(TimeSpan.FromSeconds(30), JobsStore.BackstopGap(false, false, false));
        Assert.Equal(TimeSpan.FromSeconds(30), JobsStore.BackstopGap(true, true, true));
        Assert.Equal(TimeSpan.FromSeconds(90), JobsStore.BackstopGap(true, true, false));
    }

    [Fact]
    public void TheCacheKeepsTheLongestPrefixThatFits()
    {
        var jobs = Enumerable.Range(0, 600).Select(i => new CronJob($"j{i}") { Prompt = new string('x', 500) }).ToList();
        var text = JobsStore.FittingJobs(jobs, 1, JobsStore.CacheLimit)!;
        Assert.True(text.Length <= JobsStore.CacheLimit);
        var kept = CronJob.List(JsonNode.Parse(text)!["value"]);
        Assert.Equal(250, kept.Count);
        Assert.Null(JobsStore.FittingJobs(jobs, 1, 100));
    }

    [Fact]
    public async Task ListsSortsAndPaintsFromTheCache()
    {
        var api = new FakeApi
        {
            Answer = (_, path, _) => path == JobsApi.ListPath
                ? JsonNode.Parse("""[{"id":"2","name":"Job 10"},{"id":"1","name":"job 2"},{"id":"3","name":"gbrain-update","profile":"r"},{"id":"4","name":"GBrain notes"}]""")
                : path == JobsApi.BotWorkingPath ? JsonNode.Parse("""{"jobs":[{"profile":"","id":"1","status":"queued"}]}""") : null,
        };
        var dir = Path.Combine(Path.GetTempPath(), "hq-jobs-" + Guid.NewGuid().ToString("N"));
        var cache = new JobsDiskCache(dir);
        using (var store = new JobsStore(api, cache))
        {
            Assert.False(store.HasList);
            await store.RefreshAsync();
            Assert.True(store.HasList);
            Assert.Equal(["GBrain notes", "GBrain update", "job 2", "Job 10"], store.Jobs.Select(store.Title));
            Assert.Equal("queued", store.Job("default|1")!.BotWorking);
            Assert.Equal(1, store.WorkingCount);
        }
        using var again = new JobsStore(new FakeApi(), cache);
        Assert.True(again.HasList);
        Assert.Equal(4, again.Jobs.Count);
        Directory.Delete(dir, true);
    }

    [Fact]
    public async Task WritesAreRefusedWhileReadOnlyAndRemoveOnDelete()
    {
        var api = new FakeApi { Answer = (_, path, _) => path == JobsApi.ListPath ? JsonNode.Parse("""[{"id":"a","name":"A"}]""") : null };
        using var store = new JobsStore(api);
        await store.RefreshAsync();
        var job = store.Jobs[0];
        store.ReadOnlyGateway = true;
        Assert.Equal(WriteKind.Refused, (await store.DeleteAsync(job)).Kind);
        Assert.Equal(RunKind.Refused, (await store.RunNowAsync(job)).Kind);
        Assert.DoesNotContain(api.Calls, c => c.Method != "GET");
        store.ReadOnlyGateway = false;
        api.Answer = (_, _, _) => null;
        Assert.Equal(WriteKind.Done, (await store.DeleteAsync(job)).Kind);
        Assert.Empty(store.Jobs);
        Assert.Contains("default|a", store.DeletedHere);
    }

    [Fact]
    public void TheEditorSendsOnlyWhatChanged()
    {
        using var store = new JobsStore(new FakeApi());
        var job = new CronJob("p") { Name = "Family dinner plan", Prompt = "Plan dinner", Schedule = new CronSchedule { Kind = "cron", Expr = "30 18 * * 3" },
            Deliver = "telegram:-100123:7", Model = "retired-model-1", Provider = "oldco" };
        var edit = new JobEditorModel(store, job, [("default", "Hermes")], "default");
        Assert.Equal(JobFrequency.Weekly, edit.Form.Frequency);
        Assert.Null(edit.Updates());
        Assert.False(edit.IsDirty);
        edit.SetFields(edit.Fields with { Hour = 19 });
        Assert.Equal("""{"schedule":"30 19 * * 3"}""", edit.Updates()!.ToJsonString());
        edit.SetModel(null);
        Assert.Equal("""{"schedule":"30 19 * * 3","model":null,"provider":null}""", edit.Updates()!.ToJsonString());
        Assert.True(edit.IsDirty);
        Assert.Equal("Edit Job", edit.Title);
        Assert.Equal("Next run: ", edit.NextRunWords()![..10]);

        var create = new JobEditorModel(store, null, [("default", "Hermes"), ("research", "Research")], "default");
        Assert.True(create.ShowsBotRow);
        Assert.Equal("Prompt and schedule are required.", (create.SetCustomScheduleThen("")).Validate());
        create.SetFrequency(JobFrequency.Daily);
        Assert.Equal("Prompt is required.", create.Validate());
        create.SetPrompt("Summarize the inbox\nand more");
        Assert.Equal("Summarize the inbox and more", create.SuggestedName);
        Assert.True(create.ToggleDelivery("telegram"));
        Assert.Equal("""{"prompt":"Summarize the inbox\nand more","schedule":"0 9 * * *","deliver":"telegram"}""", create.CreateBody().ToJsonString());
        create.SetModel(new JobModelChoice("anthropic", "claude-sonnet-5"));
        Assert.Equal("claude-sonnet-5", create.CreateBody()["model"]!.GetValue<string>());
        create.SetFrequency(JobFrequency.Weekly);
        Assert.True(create.ToggleWeekday(3));
        Assert.Equal("0 9 * * 1,3", create.Form.Schedule);
        Assert.True(create.ToggleWeekday(1));
        Assert.False(create.ToggleWeekday(3), "the last day stays on");
        Assert.Equal("Applies to this job only. Default uses Hermes’s own model.", JobWords.ModelScope("Hermes"));
    }
}

internal static class EditorTestHelp
{
    public static JobEditorModel SetCustomScheduleThen(this JobEditorModel m, string text)
    {
        m.SetFrequency(JobFrequency.Custom);
        m.SetCustomSchedule(text);
        return m;
    }
}
