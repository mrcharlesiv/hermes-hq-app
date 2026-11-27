using System.Globalization;
using System.Text.Json.Nodes;

namespace Hermes.Core.Jobs;

/// The Jobs page's wire shapes (HermesKit/Pages/PagesWire.swift, docs/spec/1x-pages.md §3.1). REST only, decoded
/// leniently: unknown keys ignored, every documented key optional, a number where text is expected read as text.
public static class JobJson
{
    /// A string, or a number written as one ("chat_id": 100000001 → "100000001"); null for null/absent.
    public static string? PgString(JsonNode? v) => v switch
    {
        JsonValue jv when jv.TryGetValue(out string? s) => s,
        JsonValue jv when jv.TryGetValue(out double d) =>
            Math.Round(d) == d && Math.Abs(d) < 9.007e15 ? ((long)d).ToString(CultureInfo.InvariantCulture) : d.ToString(CultureInfo.InvariantCulture),
        JsonValue jv when jv.TryGetValue(out bool b) => b ? "true" : "false",
        _ => null,
    };

    /// A string only (JSONValue.string).
    public static string? StrictString(JsonNode? v) => v is JsonValue jv && jv.TryGetValue(out string? s) ? s : null;

    public static bool? StrictBool(JsonNode? v) => v is JsonValue jv && jv.TryGetValue(out bool b) ? b : null;

    public static double? Number(JsonNode? v) => v switch
    {
        JsonValue jv when jv.TryGetValue(out double d) => d,
        JsonValue jv when jv.TryGetValue(out string? s) && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
        _ => null,
    };

    /// Seconds since the epoch from a number or numeric string; null when absent or not positive.
    public static double? Seconds(JsonNode? v) => Number(v) is { } d && double.IsFinite(d) && d > 0 ? d : null;

    public static JsonArray? Array(JsonNode? v) => v as JsonArray;
    public static JsonNode? Key(JsonNode? v, string key) => v is JsonObject o && o.TryGetPropertyValue(key, out var x) ? x : null;
}

public sealed record CronSchedule
{
    public string? Kind { get; set; }
    public string? Expr { get; set; }
    public string? Display { get; set; }
    public double? Minutes { get; set; }
    public string? RunAt { get; set; }

    public static CronSchedule? Parse(JsonNode? json)
    {
        if (json is not JsonObject) return null;
        return new CronSchedule
        {
            Kind = JobJson.StrictString(json.Get("kind")),
            Expr = JobJson.StrictString(json.Get("expr")),
            Display = JobJson.StrictString(json.Get("display")),
            Minutes = JobJson.Number(json.Get("minutes")),
            RunAt = JobJson.StrictString(json.Get("run_at")),
        };
    }

    public JsonObject ToJson() => new()
    {
        ["kind"] = Kind, ["expr"] = Expr, ["display"] = Display, ["minutes"] = Minutes, ["run_at"] = RunAt,
    };
}

public sealed record CronOrigin
{
    public string? Platform { get; set; }
    public string? ChatId { get; set; }
    public string? ChatName { get; set; }
    public string? ThreadId { get; set; }

    public static CronOrigin? Parse(JsonNode? json)
    {
        if (json is not JsonObject) return null;
        return new CronOrigin
        {
            Platform = JobJson.PgString(json.Get("platform")),
            ChatId = JobJson.PgString(json.Get("chat_id")),
            ChatName = JobJson.PgString(json.Get("chat_name")),
            ThreadId = JobJson.PgString(json.Get("thread_id")),
        };
    }

    public JsonObject ToJson() => new() { ["platform"] = Platform, ["chat_id"] = ChatId, ["chat_name"] = ChatName, ["thread_id"] = ThreadId };
}

/// One job of `GET /api/cron/jobs` (§3.1).
public sealed record CronJob
{
    public CronJob(string id) => Id = id;

    public string Id { get; set; }
    public string? Name { get; set; }
    public string? Prompt { get; set; }
    public string? Script { get; set; }
    public bool NoAgent { get; set; }
    public CronSchedule? Schedule { get; set; }
    public string? ScheduleDisplay { get; set; }
    public bool? Enabled { get; set; }
    public string? State { get; set; }
    public string? NextRunAt { get; set; }
    public string? LastRunAt { get; set; }
    public string? LastStatus { get; set; }
    public string? LastError { get; set; }
    public string? Deliver { get; set; }
    public CronOrigin? Origin { get; set; }
    public string? Model { get; set; }
    public string? Provider { get; set; }
    public string? Profile { get; set; }
    public string? ProfileName { get; set; }
    public string? HermesHome { get; set; }
    /// The job's latest run attempt (`latest_execution`, Hermes 0.21+): its status and when the scheduler claimed it.
    public string? LatestRunStatus { get; set; }
    public string? LatestRunClaimedAt { get; set; }
    /// A bot is still working on what the latest run handed it ("queued" or "claimed"), from the Hermes HQ add-on.
    public string? BotWorking { get; set; }

    public static CronJob? Parse(JsonNode? json)
    {
        if (JobJson.PgString(json.Get("id")) is not { Length: > 0 } id) return null;
        var exec = json.Get("latest_execution");
        return new CronJob(id)
        {
            Name = JobJson.StrictString(json.Get("name")),
            Prompt = JobJson.StrictString(json.Get("prompt")),
            Script = JobJson.StrictString(json.Get("script")),
            NoAgent = JobJson.StrictBool(json.Get("no_agent")) ?? false,
            Schedule = CronSchedule.Parse(json.Get("schedule")),
            ScheduleDisplay = JobJson.StrictString(json.Get("schedule_display")),
            Enabled = JobJson.StrictBool(json.Get("enabled")),
            State = JobJson.StrictString(json.Get("state")),
            NextRunAt = JobJson.StrictString(json.Get("next_run_at")),
            LastRunAt = JobJson.StrictString(json.Get("last_run_at")),
            LastStatus = JobJson.StrictString(json.Get("last_status")),
            LastError = JobJson.StrictString(json.Get("last_error")),
            Deliver = JobJson.StrictString(json.Get("deliver")),
            Origin = CronOrigin.Parse(json.Get("origin")),
            Model = JobJson.StrictString(json.Get("model")),
            Provider = JobJson.StrictString(json.Get("provider")),
            Profile = JobJson.StrictString(json.Get("profile")),
            ProfileName = JobJson.StrictString(json.Get("profile_name")),
            HermesHome = JobJson.StrictString(json.Get("hermes_home")),
            LatestRunStatus = JobJson.StrictString(exec.Get("status")),
            LatestRunClaimedAt = JobJson.StrictString(exec.Get("claimed_at")),
        };
    }

    /// The gateway's shape again (the disk cache), so Parse reads it back.
    public JsonObject ToJson()
    {
        var o = new JsonObject
        {
            ["id"] = Id, ["name"] = Name, ["prompt"] = Prompt, ["script"] = Script, ["no_agent"] = NoAgent,
            ["schedule"] = Schedule?.ToJson(), ["schedule_display"] = ScheduleDisplay, ["enabled"] = Enabled, ["state"] = State,
            ["next_run_at"] = NextRunAt, ["last_run_at"] = LastRunAt, ["last_status"] = LastStatus, ["last_error"] = LastError,
            ["deliver"] = Deliver, ["origin"] = Origin?.ToJson(), ["model"] = Model, ["provider"] = Provider,
            ["profile"] = Profile, ["profile_name"] = ProfileName, ["hermes_home"] = HermesHome,
        };
        if (LatestRunStatus != null || LatestRunClaimedAt != null)
            o["latest_execution"] = new JsonObject { ["status"] = LatestRunStatus, ["claimed_at"] = LatestRunClaimedAt };
        return o;
    }

    /// The profile that owns the job: per-job calls name it (§3.1).
    public string Owner => Profile is { Length: > 0 } p ? p : ProfileName is { Length: > 0 } n ? n : "default";

    /// `<profile>|<id>`: ids repeat across profiles (§3.2).
    public string Key => Owner + "|" + Id;

    public static List<CronJob> List(JsonNode? json)
    {
        var rows = json as JsonArray ?? json.Arr("jobs") ?? [];
        return [.. rows.Select(Parse).OfType<CronJob>()];
    }
}

/// What a run row opens (§3.7).
public abstract record RunOpens
{
    public sealed record Chat : RunOpens;
    public sealed record Document(string Stem) : RunOpens;
    public sealed record Nothing : RunOpens;
}

/// One row of a job's run history (`GET /api/cron/jobs/<id>/runs`).
public sealed record CronRun
{
    public CronRun(string id) => Id = id;

    public string Id { get; set; }
    public string? Source { get; set; }
    public string? Title { get; set; }
    public string? Preview { get; set; }
    public int? MessageCount { get; set; }
    public double? StartedAt { get; set; }
    public double? LastActive { get; set; }
    public double? EndedAt { get; set; }
    public bool IsActive { get; set; }
    public string? Profile { get; set; }

    public static CronRun? Parse(JsonNode? json)
    {
        if (JobJson.PgString(json.Get("id")) is not { Length: > 0 } id) return null;
        return new CronRun(id)
        {
            Source = JobJson.StrictString(json.Get("source")),
            Title = JobJson.StrictString(json.Get("title")),
            Preview = JobJson.StrictString(json.Get("preview")),
            MessageCount = JobJson.Number(json.Get("message_count")) is { } n ? (int)n : null,
            StartedAt = JobJson.Seconds(json.Get("started_at")),
            LastActive = JobJson.Seconds(json.Get("last_active")),
            EndedAt = JobJson.Seconds(json.Get("ended_at")),
            IsActive = JobJson.StrictBool(json.Get("is_active")) ?? false,
            Profile = JobJson.StrictString(json.Get("profile")),
        };
    }

    public static List<CronRun> List(JsonNode? json)
    {
        var rows = json.Arr("runs") ?? json as JsonArray ?? [];
        return [.. rows.Select(Parse).OfType<CronRun>()];
    }

    public RunOpens Opens
    {
        get
        {
            if (Source != "cron_output") return new RunOpens.Chat();
            // cron_output:<job>:<stem> | cron_output:<job>:exec:<n> | cron_output:<job>:latest
            var parts = Id.Split(':');
            if (parts.Length < 3 || parts[0] != "cron_output") return new RunOpens.Nothing();
            if (parts.Length >= 4 && parts[2] == "exec") return new RunOpens.Nothing();
            var stem = string.Join(":", parts.Skip(2));
            if (stem == "latest" || stem.Length == 0) return new RunOpens.Nothing();
            return new RunOpens.Document(stem);
        }
    }
}
