using System.Text.Json;

namespace Hermes.Core.Jobs;

public enum JobsBadgeClear { WhenFixed, WhenSeen }

/// The Jobs tab's attention count (HermesKit/Pages/JobsBadge.swift).
public static class JobsBadge
{
    public const int SeenLimit = 500;
    public static string? Mark(CronJob job, DateTimeOffset now)
    {
        if (JobWords.Section(job, now) != JobSection.NeedsAttention) return null;
        var parts = new List<string> { job.Key, JobWords.JobState(job) };
        if (JobWords.LastRunFailed(job)) parts.Add("failed " + (job.LastRunAt ?? ""));
        if (JobWords.NextRunOverdue(job, now) != null) parts.Add("overdue " + (job.NextRunAt ?? ""));
        return string.Join("|", parts);
    }

    public static HashSet<string> Marks(IEnumerable<CronJob> jobs, DateTimeOffset now) =>
        jobs.Select(j => Mark(j, now)).OfType<string>().ToHashSet();

    public static int Count(IEnumerable<CronJob> jobs, DateTimeOffset now, JobsBadgeClear clear, ISet<string> seen) =>
        jobs.Select(j => Mark(j, now)).OfType<string>().Count(mark => clear == JobsBadgeClear.WhenFixed || !seen.Contains(mark));

    public static DateTimeOffset? NextChange(IEnumerable<CronJob> jobs, DateTimeOffset now) => jobs
        .Where(j => JobWords.Section(j, now) != JobSection.NeedsAttention && JobWords.JobState(j) is not ("paused" or "completed" or "disabled"))
        .Select(j => PagesDate.Parse(j.NextRunAt)?.Add(JobWords.OverdueGrace).AddSeconds(1))
        .Where(at => at > now).Min();

    public static List<string> Remember(IEnumerable<string> old, IEnumerable<CronJob> jobs, DateTimeOffset now)
    {
        var order = old.ToList();
        var seen = order.ToHashSet();
        order.AddRange(Marks(jobs, now).Where(mark => !seen.Contains(mark)).Order(StringComparer.Ordinal));
        if (order.Count > SeenLimit) order.RemoveRange(0, order.Count - SeenLimit);
        return order;
    }

    public static string? Title(int count) => count <= 0 ? null : count > 99 ? "99+" : count.ToString();
    public static string? Accessibility(int running, int attention)
    {
        var parts = new List<string>();
        if (running > 0) parts.Add($"{running} running");
        if (attention > 0) parts.Add($"{attention} {(attention == 1 ? "needs" : "need")} attention");
        return parts.Count == 0 ? null : string.Join(", ", parts);
    }
}

/// Seen marks live in the account's Jobs cache, and are removed with that cache at sign-out.
public sealed class JobsBadgeHistory
{
    public const string CacheName = "jobs-badge-seen";
    private readonly IJobsCache? _cache;
    public IReadOnlyList<string> Seen { get; private set; }

    public JobsBadgeHistory(IJobsCache? cache)
    {
        _cache = cache;
        try { Seen = JsonSerializer.Deserialize<List<string>>(cache?.Read(CacheName) ?? "[]") ?? []; }
        catch (JsonException) { Seen = []; }
    }

    public void MarkSeen(IEnumerable<CronJob> jobs, DateTimeOffset now)
    {
        var next = JobsBadge.Remember(Seen, jobs, now);
        if (next.SequenceEqual(Seen)) return;
        Seen = next;
        _cache?.Write(CacheName, JsonSerializer.Serialize(next));
    }
}
