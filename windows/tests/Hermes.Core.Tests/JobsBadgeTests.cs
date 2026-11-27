using Hermes.Core.Jobs;
using Xunit;

namespace Hermes.Core.Tests;

public class JobsBadgeTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-11-20T12:00:00Z");
    private static CronJob Job(string id) => new(id) { LastStatus = "ok", LastRunAt = "2026-11-20T11:00:00Z", NextRunAt = "2026-11-20T13:00:00Z" };
    private static CronJob Failed(string id) => Job(id) with { LastStatus = "error" };

    [Fact] public void NeedsAttentionExcludesInactiveAndRunning()
    {
        var jobs = new[] { Job("ok"), Failed("f"), Job("late") with { NextRunAt = "2026-11-20T11:00:00Z" },
            Job("error") with { State = "error" }, Failed("p") with { State = "paused" },
            Failed("d") with { Enabled = false }, Failed("c") with { State = "completed" },
            Failed("running") with { LatestRunStatus = "running" } };
        Assert.Equal(3, JobsBadge.Count(jobs, Now, JobsBadgeClear.WhenFixed, new HashSet<string>()));
    }

    [Fact] public void SeenIsPerProblemAndProfileAndFixedIgnoresSeen()
    {
        var jobs = new[] { Failed("same") with { Profile = "default" }, Failed("same") with { Profile = "research" } };
        var seen = JobsBadge.Marks([jobs[0]], Now);
        Assert.Equal(1, JobsBadge.Count(jobs, Now, JobsBadgeClear.WhenSeen, seen));
        Assert.Equal(2, JobsBadge.Count(jobs, Now, JobsBadgeClear.WhenFixed, seen));
        Assert.Equal(1, JobsBadge.Count([jobs[0] with { LastRunAt = "2026-11-20T11:30:00Z" }], Now, JobsBadgeClear.WhenSeen, seen));
        Assert.Equal(0, JobsBadge.Count([Job("same")], Now, JobsBadgeClear.WhenFixed, seen));
    }

    [Fact] public void NextChangeUsesGraceAndSkipsInactiveAndAlreadyAttention()
    {
        var soon = Job("soon") with { NextRunAt = "2026-11-20T11:50:00Z" };
        var at = DateTimeOffset.Parse("2026-11-20T12:05:01Z");
        Assert.Equal(at, JobsBadge.NextChange([soon, Job("later"), Failed("p") with { State = "paused" }, Failed("f")], Now));
        Assert.Equal(0, JobsBadge.Count([soon], at.AddSeconds(-2), JobsBadgeClear.WhenFixed, new HashSet<string>()));
        Assert.Equal(1, JobsBadge.Count([soon], at, JobsBadgeClear.WhenFixed, new HashSet<string>()));
        Assert.Null(JobsBadge.NextChange([Failed("f"), Job("p") with { State = "paused" }], Now));
    }

    [Fact] public void SeenHistoryRetainsNewestFiveHundred()
    {
        var old = Enumerable.Range(0, 500).Select(i => $"old-{i}").ToList();
        var kept = JobsBadge.Remember(old, [Failed("f")], Now);
        Assert.Equal(500, kept.Count);
        Assert.Equal("old-1", kept[0]);
        Assert.Contains(JobsBadge.Mark(Failed("f"), Now), kept);
        Assert.Equal(kept, JobsBadge.Remember(kept, [Failed("f")], Now));
    }

    private sealed class Cache : IJobsCache
    {
        private readonly Dictionary<string, string> _data = [];
        public string? Read(string name) => _data.GetValueOrDefault(name);
        public void Write(string name, string text) => _data[name] = text;
        public void Delete(string name) => _data.Remove(name);
    }

    private sealed class FakeApi() : JobsApi(null!)
    {
        public override Task<System.Text.Json.Nodes.JsonNode?> SendAsync(HttpMethod method, string path,
            IEnumerable<KeyValuePair<string, string>>? query = null, System.Text.Json.Nodes.JsonNode? body = null,
            TimeSpan? timeout = null, CancellationToken ct = default) => Task.FromResult<System.Text.Json.Nodes.JsonNode?>(null);
    }

    [Fact] public void VisibilityChangesAreObservableAndCounted()
    {
        using var store = new JobsStore(new FakeApi());
        var visibility = new System.Collections.Concurrent.ConcurrentQueue<bool>();
        store.Changed += () => visibility.Enqueue(store.IsShowing);
        store.NoteAppear();
        Assert.True(store.IsShowing);
        store.NoteAppear();
        store.NoteDisappear();
        Assert.True(store.IsShowing);
        store.NoteDisappear();
        Assert.False(store.IsShowing);
        Assert.Contains(true, visibility);
        Assert.Contains(false, visibility);
    }

    [Fact] public void SeenPersistsPerAccountAndCanBeForgotten()
    {
        var first = new Cache();
        var other = new Cache();
        var history = new JobsBadgeHistory(first);
        history.MarkSeen([Failed("f")], Now);
        Assert.Single(new JobsBadgeHistory(first).Seen);
        Assert.Empty(new JobsBadgeHistory(other).Seen);
        Assert.Equal(0, JobsBadge.Count([Failed("f")], Now, JobsBadgeClear.WhenSeen, new JobsBadgeHistory(first).Seen.ToHashSet()));
        first.Delete(JobsBadgeHistory.CacheName);
        Assert.Empty(new JobsBadgeHistory(first).Seen);
        first.Write(JobsBadgeHistory.CacheName, "not json");
        Assert.Empty(new JobsBadgeHistory(first).Seen);
    }

    [Fact] public void BadgeWordsMatchTheSwiftReference()
    {
        Assert.Null(JobsBadge.Title(0));
        Assert.Equal("99+", JobsBadge.Title(100));
        Assert.Equal("1 running, 1 needs attention", JobsBadge.Accessibility(1, 1));
        Assert.Equal("2 need attention", JobsBadge.Accessibility(0, 2));
        Assert.Null(JobsBadge.Accessibility(0, 0));
    }
}
