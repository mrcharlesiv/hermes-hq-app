using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Composer;

namespace Hermes.Core.Insights;

/// The fields of a Hermes cron job a tile needs (HermesKit/Pages/PagesWire.swift `CronJob`).
public sealed record TileCronJob
{
    public required string Id { get; init; }
    public string? Name { get; init; }
    public string? Prompt { get; init; }
    public string? Script { get; init; }
    public bool NoAgent { get; init; }
    public string? ScheduleExpr { get; init; }
    public double? ScheduleMinutes { get; init; }
    public string? ScheduleDisplay { get; init; }
    public bool? Enabled { get; init; }
    public string? State { get; init; }
    public string? NextRunAt { get; init; }
    public string? LastRunAt { get; init; }
    public string? LastStatus { get; init; }
    public string? LastError { get; init; }
    public string? Model { get; init; }
    public string? Provider { get; init; }
    public string? Profile { get; init; }
    public string? ProfileName { get; init; }
    public string? LatestRunStatus { get; init; }
    public string? LatestRunClaimedAt { get; init; }
    public string? BotWorking { get; init; }

    public string Owner => !string.IsNullOrEmpty(Profile) ? Profile! : !string.IsNullOrEmpty(ProfileName) ? ProfileName! : "default";
    public string Key => Owner + "|" + Id;

    public static TileCronJob? FromJson(JsonNode? j)
    {
        if (j.Str("id") is not { Length: > 0 } id) return null;
        var schedule = j.Get("schedule");
        return new TileCronJob
        {
            Id = id, Name = j.Str("name"), Prompt = j.Str("prompt"), Script = j.Str("script"), NoAgent = j.Bool("no_agent") ?? false,
            ScheduleExpr = schedule is JsonObject ? schedule.Str("expr") : null,
            ScheduleMinutes = schedule is JsonObject ? schedule.Num("minutes") : null,
            ScheduleDisplay = j.Str("schedule_display") ?? (schedule is JsonObject ? schedule.Str("display") : J.AsString(schedule)),
            Enabled = j.Bool("enabled"), State = j.Str("state"), NextRunAt = j.Str("next_run_at"), LastRunAt = j.Str("last_run_at"),
            LastStatus = j.Str("last_status"), LastError = j.Str("last_error"), Model = j.Str("model"), Provider = j.Str("provider"),
            Profile = j.Str("profile"), ProfileName = j.Str("profile_name"),
            LatestRunStatus = j.Obj("latest_execution").Str("status"), LatestRunClaimedAt = j.Obj("latest_execution").Str("claimed_at"),
        };
    }

    /// `GET /api/cron/jobs` answers an array, or `{"jobs": [...]}`.
    public static List<TileCronJob> List(JsonNode? json) =>
        [.. (json as JsonArray ?? json.Arr("jobs") ?? []).Select(FromJson).OfType<TileCronJob>()];
}

/// The gateway's ISO times as JS `new Date(iso)` reads them (`PagesDate`): with a zone that instant; without one the
/// local wall clock; a date alone UTC midnight.
public static partial class TileDates
{
    public static DateTimeOffset? Parse(string? text, TimeZoneInfo? zone = null)
    {
        var t = text?.Trim();
        if (string.IsNullOrEmpty(t)) return null;
        var g = IsoRx().Match(t);
        if (!g.Success) return null;
        int y = int.Parse(g.Groups[1].Value), mo = int.Parse(g.Groups[2].Value), d = int.Parse(g.Groups[3].Value);
        int h = g.Groups[4].Success ? int.Parse(g.Groups[4].Value) : 0, mi = g.Groups[5].Success ? int.Parse(g.Groups[5].Value) : 0;
        int s = g.Groups[6].Success ? int.Parse(g.Groups[6].Value) : 0;
        if (mo is < 1 or > 12 || d is < 1 or > 31 || h > 23 || mi > 59 || s > 60) return null;
        if (d > DateTime.DaysInMonth(y, mo)) return null;
        var fraction = g.Groups[7].Success ? double.Parse("0." + g.Groups[7].Value, CultureInfo.InvariantCulture) : 0;
        var wall = new DateTime(y, mo, d, h, mi, Math.Min(s, 59), DateTimeKind.Unspecified).AddSeconds(fraction + (s == 60 ? 1 : 0));
        TimeSpan offset;
        if (g.Groups[8].Success) offset = TimeSpan.FromMinutes(OffsetMinutes(g.Groups[8].Value));
        else if (!g.Groups[4].Success) offset = TimeSpan.Zero;
        else offset = (zone ?? TimeZoneInfo.Local).GetUtcOffset(wall);
        return new DateTimeOffset(wall, offset);
    }

    public static int OffsetMinutes(string zone)
    {
        if (zone == "Z") return 0;
        var digits = zone[1..].Replace(":", "");
        if (digits.Length != 4 || !int.TryParse(digits[..2], out var hh) || !int.TryParse(digits[2..], out var mm)) return 0;
        var m = hh * 60 + mm;
        return zone[0] == '-' ? -m : m;
    }

    [GeneratedRegex(@"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?\s*(Z|[+-]\d{2}:?\d{2})?$")]
    private static partial Regex IsoRx();
}

/// The job that keeps a tile up to date, and how often it runs (TileNames.swift `TileJobs`).
public static class TileJobs
{
    public sealed record Frequency(string Title, string Short, string Cron, int Minutes);

    public static readonly Frequency[] Frequencies =
    [
        new("Every 15 Minutes", "every 15 min", "*/15 * * * *", 15),
        new("Every 30 Minutes", "every 30 min", "*/30 * * * *", 30),
        new("Every Hour", "hourly", "0 * * * *", 60),
        new("Every 3 Hours", "every 3 hours", "0 */3 * * *", 180),
        new("Every 6 Hours", "every 6 hours", "0 */6 * * *", 360),
        new("Once a Day", "daily", "0 8 * * *", 1440),
    ];

    private static string LastPathComponent(string path) => path.Split('/').LastOrDefault(s => s.Length > 0) ?? "";

    /// The job keeping `path` (of bot `profile`) up to date: the one the page names, else the best of the bot's jobs
    /// naming the file (its whole path first, then its refresh script, then its file name alone).
    public static TileCronJob? Match(string path, string profile, string? jobId, IReadOnlyList<TileCronJob> jobs)
    {
        var own = jobs.Where(j => j.Owner == profile).ToList();
        if (jobId != null && (own.FirstOrDefault(j => j.Id == jobId) ?? jobs.FirstOrDefault(j => j.Id == jobId)) is { } named) return named;
        var file = LastPathComponent(path);
        if (file.Length == 0) return null;
        var dot = file.LastIndexOf('.');
        var stem = dot > 0 ? file[..dot] : file;
        var paths = new List<string> { path };
        if (path.StartsWith("~/")) paths.Add(path[1..]);
        else if (Regex.Match(path, "^/(home|Users)/[^/]+/") is { Success: true } home) paths.Add("~/" + path[home.Length..]);
        (TileCronJob Job, int Score)? best = null;
        foreach (var job in own)
        {
            var text = string.Join("\n", new[] { job.Prompt, job.Script, job.Name }.OfType<string>());
            var score = 0;
            if (paths.Any(p => text.Contains(p))) score = 3;
            else if (text.Contains(stem + ".refresh") || text.Contains(stem + "_refresh")) score = 2;
            else if (text.Contains(file)) score = 1;
            if (score == 0) continue;
            var rank = score * 2 + (IsPaused(job) ? 0 : 1);
            if (rank > (best?.Score ?? 0)) best = (job, rank);
        }
        return best?.Job;
    }

    public static bool IsPaused(TileCronJob job) => job.Enabled == false || job.State?.ToLowerInvariant() == "paused";

    /// The menu's choice the job runs at, null when it runs at another time.
    public static Frequency? FrequencyOf(TileCronJob job)
    {
        if (job.ScheduleExpr?.Trim() is { } expr && Frequencies.FirstOrDefault(f => f.Cron == expr) is { } hit) return hit;
        if (job.ScheduleMinutes is { } m && Frequencies.FirstOrDefault(f => f.Minutes == m) is { } hit2) return hit2;
        var display = (job.ScheduleDisplay ?? "").ToLowerInvariant().Replace(" ", "");
        var words = new Dictionary<string, int>
        {
            ["every15m"] = 15, ["every30m"] = 30, ["every60m"] = 60, ["every1h"] = 60, ["every180m"] = 180, ["every3h"] = 180,
            ["every360m"] = 360, ["every6h"] = 360, ["every1440m"] = 1440, ["every24h"] = 1440, ["every1d"] = 1440,
        };
        return words.TryGetValue(display, out var minutes) ? Frequencies.FirstOrDefault(f => f.Minutes == minutes) : null;
    }

    /// How often, in a few lower-case words ("every 15 min", "weekdays at 9:00 AM").
    public static string HowOften(TileCronJob job)
    {
        if (FrequencyOf(job) is { } hit) return hit.Short;
        var shown = (job.ScheduleDisplay ?? job.ScheduleExpr ?? "").Trim();
        if (shown.Length == 0) return "on a schedule";
        return char.ToLowerInvariant(shown[0]) + shown[1..];
    }

    private static bool Failed(TileCronJob job) => (job.LastStatus?.ToLowerInvariant() ?? "") is "error" or "failed";

    /// The tile's update line: "Updated 5 min ago · every 15 min", "Updates paused", "Not updated yet · hourly".
    public static string Status(TileCronJob job, DateTimeOffset now)
    {
        if (IsPaused(job)) return "Updates paused";
        var often = HowOften(job);
        if (TileDates.Parse(job.LastRunAt) is not { } last) return "Not updated yet · " + often;
        return (Failed(job) ? "Update failed " : "Updated ") + Ago(last, now) + " · " + often;
    }

    /// The opened tile's line under its name, after the file name: "updated 5 min ago", "updates paused".
    public static string ShortStatus(TileCronJob job, DateTimeOffset now)
    {
        if (IsPaused(job)) return "updates paused";
        if (TileDates.Parse(job.LastRunAt) is not { } last) return "not updated yet";
        return "updated " + Ago(last, now);
    }

    /// How a tile's updates are going: the tile wears a small mark for all but Fine and None.
    public enum HealthKind { None, Fine, Updating, Failed, Late, Paused }
    public readonly record struct Health(HealthKind Kind, string? Why = null)
    {
        public static readonly Health None = new(HealthKind.None);
    }

    /// The latest run is claimed or running, and the job not marked run since it was claimed (`JobWords.runIsOut`).
    public static bool WorkIsOut(TileCronJob job)
    {
        if (job.BotWorking != null) return true;
        var status = (job.LatestRunStatus ?? "").Trim().ToLowerInvariant();
        if (status is not ("claimed" or "running")) return false;
        if (TileDates.Parse(job.LastRunAt) is not { } last || TileDates.Parse(job.LatestRunClaimedAt) is not { } claimed) return true;
        return last < claimed;
    }

    public static Health HealthOf(TileCronJob? job, DateTimeOffset now)
    {
        if (job == null) return Health.None;
        if (IsPaused(job)) return new(HealthKind.Paused);
        if (WorkIsOut(job)) return new(HealthKind.Updating);
        if (Failed(job))
        {
            var why = job.LastError?.Split('\n', '\r').FirstOrDefault()?.Trim();
            return new(HealthKind.Failed, string.IsNullOrEmpty(why) ? null : why);
        }
        var every = TimeSpan.FromMinutes(FrequencyOf(job)?.Minutes ?? 60);
        var grace = TimeSpan.FromSeconds(Math.Max(15 * 60, every.TotalSeconds / 2));
        if (TileDates.Parse(job.NextRunAt) is { } next && now - next > grace) return new(HealthKind.Late);
        if (FrequencyOf(job) is { } f && TileDates.Parse(job.LastRunAt) is { } lastRun && now - lastRun > TimeSpan.FromMinutes(f.Minutes) * 2 + grace)
            return new(HealthKind.Late);
        return new(HealthKind.Fine);
    }

    /// Read out after the tile's name (`TileHealthMark.words`).
    public static string? Spoken(Health h) => h.Kind switch
    {
        HealthKind.Failed when h.Why == TileWords.GoneWords => "page missing",
        HealthKind.Failed => "last update failed",
        HealthKind.Late => "not updated on time",
        HealthKind.Paused => "updates paused",
        HealthKind.Updating => "updating",
        _ => null,
    };

    public static bool IsScriptOnly(TileCronJob job) =>
        job.NoAgent || (string.IsNullOrWhiteSpace(job.Prompt) && !string.IsNullOrEmpty(job.Script));

    /// Who updates the tile, in words: "Sonnet 5", "Sonnet 5 (Otto's model)", "A script, no model".
    public static string ModelWords(TileCronJob job, string botName, string? botModel)
    {
        if (IsScriptOnly(job)) return "A script, no model";
        if (job.Model?.Trim() is { Length: > 0 } model) return ModelNames.DisplayModelName(model);
        if (!string.IsNullOrEmpty(botModel)) return $"{botModel} ({botName}’s model)";
        return $"{botName}’s own model";
    }

    /// The model that runs the job, by name: its pin's, else its bot's.
    public static string? RunningName(TileCronJob job, string? botModel)
    {
        if (IsScriptOnly(job)) return null;
        if (job.Model?.Trim() is { Length: > 0 } model) return ModelNames.DisplayModelName(model);
        return string.IsNullOrWhiteSpace(botModel) ? null : botModel;
    }

    /// The Updates submenu's line: "Updated 5 min ago · hourly · GPT-6.2 Astra" (`TileModels.updatesSubtitle`).
    public static string UpdatesSubtitle(TileCronJob job, string? botModel, DateTimeOffset now)
    {
        var status = Status(job, now);
        return RunningName(job, botModel) is { } name ? status + " · " + name : status;
    }

    public static string Ago(DateTimeOffset date, DateTimeOffset now)
    {
        var seconds = Math.Max(0, (now - date).TotalSeconds);
        if (seconds < 60) return "just now";
        if (seconds < 3600) return $"{(int)(seconds / 60)} min ago";
        if (seconds < 86_400) { var h = (int)(seconds / 3600); return h == 1 ? "1 hour ago" : $"{h} hours ago"; }
        var d = (int)(seconds / 86_400);
        return d == 1 ? "yesterday" : $"{d} days ago";
    }

    /// [tiles-v2] Estimated runs per day for a scheduled tile job (null when paused or unknown).
    public static double? EstimatedRunsPerDay(TileCronJob job)
    {
        if (IsPaused(job)) return null;
        if (FrequencyOf(job) is { Minutes: > 0 } freq) return 1440.0 / freq.Minutes;
        if (job.ScheduleMinutes is { } minutes && minutes > 0) return 1440.0 / minutes;
        var expr = (job.ScheduleExpr ?? "").Trim();
        if (expr.Length == 0) return null;
        var fields = expr.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length != 5) return null;
        var minF = fields[0];
        var hourF = fields[1];
        var dowF = fields[4];
        var dayFactor = dowF == "1-5" || string.Equals(dowF, "mon-fri", StringComparison.OrdinalIgnoreCase) ? 5.0 / 7.0 : 1.0;
        if (minF.StartsWith("*/", StringComparison.Ordinal) && double.TryParse(minF[2..], CultureInfo.InvariantCulture, out var minStep) && minStep > 0 && hourF == "*")
            return (1440.0 / minStep) * dayFactor;
        if (hourF.StartsWith("*/", StringComparison.Ordinal) && double.TryParse(hourF[2..], CultureInfo.InvariantCulture, out var hourStep) && hourStep > 0)
            return (24.0 / hourStep) * dayFactor;
        if (hourF == "*")
        {
            var perHour = minF == "*" ? 60.0 : minF.Split(',').Length;
            return perHour * 24.0 * dayFactor;
        }
        var hoursPerDay = (double)hourF.Split(',').Length;
        var minsPerHour = minF == "*" ? 60.0 : minF.Split(',').Length;
        return Math.Max(0, hoursPerDay * minsPerHour * dayFactor);
    }

    /// [tiles-v2] Prompt asking the bot to attach a scheduled refresh job to an existing static pinned tile.
    public static string SchedulePrompt(string path, string name, Frequency frequency) =>
        $"Keep my Hermes HQ Dashboard tile “{name}” ({path}) up to date automatically {frequency.Short} (cron: {frequency.Cron}).\n\n"
        + $"Use the hermes-hq-push:dashboard-tile skill (open it with skill_view first). Create a scheduled job that refreshes this tile’s data {frequency.Short} "
        + $"and add its <meta name=\"hq-tile-job\"> tag to {path} while keeping the tile’s look, layout and path unchanged. Run the refresh once now to verify, then end your reply with: MEDIA:{path}";

    /// [tiles-v2] Default Change Tile prefill when recovering from a failed tile update.
    public static string FixPrefill(string? error)
    {
        var trimmed = (error ?? "").Trim();
        if (trimmed.Length == 0) return "Fix why this tile’s last update failed and verify the refresh job runs cleanly";
        var line = trimmed.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? trimmed;
        var shortLine = line.Length > 140 ? line[..139] + "…" : line;
        return $"Fix why this tile’s update failed (“{shortLine}”) and verify the refresh job runs cleanly";
    }

    /// [tiles-v2] Prompt asking the bot to create a new tile modeled on an existing one.
    public static string DuplicatePrompt(string sourcePath, string sourceName, string what, TileSize? size = null, string? scheduleWords = null)
    {
        var sizeLine = size is { } s ? $" Design it to look great especially at {s.ShapeWords()}." : "";
        var scheduleLine = scheduleWords ?? "Keep it up to date with its own scheduled job on a sensible schedule, and tell me how often.";
        return $"Make me a new live tile for my Hermes HQ Dashboard based on my existing tile “{sourceName}” ({sourcePath}), but changed to show: {what}\n\n"
            + $"Use the hermes-hq-push:dashboard-tile skill (open it with skill_view first). Read {sourcePath} for its visual style and structure, then write the new tile to a NEW .html file (do not overwrite {sourcePath}).{sizeLine} "
            + $"{scheduleLine} Run check_tile.py until it passes and look at the pictures it makes.\n\n"
            + "When it's ready, end your reply with the new page alone on its own line: MEDIA:/absolute/path/to/the/new-tile.html (the app pins it to my Dashboard by itself, so don't tell me how to pin it)";
    }
}
