using System.Globalization;
using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Insights;

/// Status & Maintenance's and Usage's wire (HermesKit/Pages/More/CommandCenterWire.swift; docs/spec/3x-morepages.md
/// §15): the gateway's status, recent logs, usage and update check, read leniently, and the words and number formats the
/// pages show. A missing field reads "—"; a bad row is skipped.
public static class CommandCenterNames
{
    public const string Page = "Status & Maintenance";
    /// Its Usage tab, now a page of its own beside it.
    public const string Usage = "Usage";
}

// ------------------------------------------------------------------ status

/// `GET /api/status`: the keys Status & Maintenance shows.
public sealed record GatewayStatusReport
{
    public sealed record Platform(string Id, string State, string? Error)
    {
        public string Name => PlatformName(Id);
        public string Words => StateWords(State);
        public bool IsUp => State.ToLowerInvariant() is "connected" or "running" or "ready" or "ok";
        public bool IsDown => State.ToLowerInvariant() is "error" or "fatal" or "failed" or "crashed" || Error != null;
    }

    public string? Version { get; init; }
    public string? ReleaseDate { get; init; }
    public bool? GatewayRunning { get; init; }
    public string? GatewayState { get; init; }
    public long? ActiveSessions { get; init; }
    public IReadOnlyList<Platform> Platforms { get; init; } = [];
    /// `can_update_hermes`: false where updates are managed outside Hermes. Absent on older gateways (true).
    public bool CanUpdate { get; init; } = true;

    public static GatewayStatusReport Parse(JsonNode? json)
    {
        var platforms = new List<Platform>();
        if (json.Obj("gateway_platforms") is { } map)
        {
            var seen = new HashSet<string>();
            foreach (var (id, value) in map)
            {
                if (id.Length == 0 || !seen.Add(id)) continue;
                // An older gateway wrote the state as a bare string.
                var state = value.Str("state") ?? J.AsString(value) ?? "unknown";
                var error = value.Str("error_message") is { Length: > 0 } e ? e : null;
                platforms.Add(new Platform(id, state, error));
            }
        }
        platforms.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));
        return new GatewayStatusReport
        {
            Version = json.Str("version") is { Length: > 0 } v ? v : null,
            ReleaseDate = json.Str("release_date"),
            GatewayRunning = json.Get("gateway_running") is JsonValue jv && jv.TryGetValue(out bool b) ? b : null,
            GatewayState = json.Get("gateway_state") is JsonValue sv && sv.TryGetValue(out string? s) ? s : null,
            ActiveSessions = json.Int("active_sessions"),
            CanUpdate = json.Get("can_update_hermes") is JsonValue cv && cv.TryGetValue(out bool c) ? c : true,
            Platforms = platforms,
        };
    }

    /// "Hermes 0.21.5", as Settings › About names the gateway's Hermes.
    public string VersionWords => Version != null ? $"Hermes {Version}" : "—";
    public string GatewayWords => GatewayRunning is { } r ? (r ? "Running" : "Stopped") : "—";
    public string SessionsWords => ActiveSessions?.ToString(CultureInfo.InvariantCulture) ?? "—";

    private static readonly Dictionary<string, string> Known = new()
    {
        ["whatsapp"] = "WhatsApp", ["imessage"] = "iMessage", ["sms"] = "SMS", ["api_server"] = "API Server",
        ["homeassistant"] = "Home Assistant", ["dingtalk"] = "DingTalk", ["wecom"] = "WeCom", ["bluebubbles"] = "BlueBubbles",
        ["qqbot"] = "QQ Bot",
    };

    public static string PlatformName(string id)
    {
        if (Known.TryGetValue(id.ToLowerInvariant(), out var name)) return name;
        return string.Join(" ", id.Split(['_', '-'], StringSplitOptions.RemoveEmptyEntries)
            .Select(w => w[..1].ToUpperInvariant() + w[1..]));
    }

    public static string StateWords(string state) => state.ToLowerInvariant() switch
    {
        "connected" or "running" or "ready" or "ok" => "Connected",
        "connecting" or "starting" or "retrying" or "reconnecting" => "Connecting…",
        "disconnected" or "stopped" or "disabled" => "Disconnected",
        "error" or "fatal" or "failed" or "crashed" => "Error",
        "" or "unknown" => "—",
        _ => state[..1].ToUpperInvariant() + state[1..].Replace('_', ' '),
    };
}

/// The dashboard's headline (StatusDashboard.summary): how the gateway is, in a few words.
public sealed record StatusSummary(string Words, string Detail, StatusTone Tone)
{
    public static StatusSummary Of(GatewayStatusReport? status, string? failed, bool online)
    {
        if (failed != null) return new("Couldn’t Load Status", failed, StatusTone.Warning);
        if (status == null) return new("Loading…", "", StatusTone.Quiet);
        if (!online) return new("Not Connected", InsightsWire.OfflineFooter, StatusTone.Offline);
        if (status.GatewayRunning == false)
            return new("Messaging Is Stopped", "Bots can’t answer in their chat apps until it runs again.", StatusTone.Bad);
        var down = status.Platforms.Where(p => p.IsDown).ToList();
        if (down.Count > 0)
            return new(down.Count == 1 ? "1 App Needs Attention" : $"{down.Count} Apps Need Attention",
                $"{ListWords(down.Select(p => p.Name).ToList())} can’t connect.", StatusTone.Warning);
        return new("Everything Is Running", status.Platforms.Count == 0 ? "The gateway is up." : "The gateway and its messaging apps are up.",
            StatusTone.Good);
    }

    /// "Discord", "Discord and Slack", "Discord, Slack, and Telegram" (Foundation's `.list(type: .and)`, en-US).
    public static string ListWords(IReadOnlyList<string> names) => names.Count switch
    {
        0 => "",
        1 => names[0],
        2 => $"{names[0]} and {names[1]}",
        _ => string.Join(", ", names.Take(names.Count - 1)) + ", and " + names[^1],
    };
}

public enum StatusTone { Good, Warning, Bad, Offline, Quiet }

// ------------------------------------------------------------------ update check

/// One commit the update brings (`commits` on the check).
public sealed record HermesUpdateCommit(string Sha, string Summary, string? Author = null, double? At = null)
{
    public static HermesUpdateCommit? Parse(JsonNode? json)
    {
        if (json.Str("summary")?.Trim() is not { Length: > 0 } summary) return null;
        return new HermesUpdateCommit(json.Str("sha") ?? "", summary, json.Str("author") is { Length: > 0 } a ? a : null, json.Num("at"));
    }
}

/// `GET /api/hermes/update/check`.
public sealed record HermesUpdateCheck
{
    /// Commits behind: 0 up to date, -1 behind by an unknown count, null when the check could not run.
    public long? Behind { get; set; }
    public bool UpdateAvailable { get; set; }
    /// Only an in-place (git) install can be updated from here; otherwise `Message` says what to do.
    public bool CanApply { get; init; }
    public string? Message { get; init; }
    public string? CurrentVersion { get; set; }
    public string? Command { get; init; }
    public string? InstallMethod { get; init; }
    public string? Channel { get; init; }
    public string? SourceVersion { get; init; }
    public string? Held { get; init; }
    public string? RollbackTo { get; init; }
    public IReadOnlyList<HermesUpdateCommit> Commits { get; init; } = [];

    private static string? NonEmpty(string? s) => string.IsNullOrEmpty(s) ? null : s;

    public static HermesUpdateCheck Parse(JsonNode? json)
    {
        var behind = json.Int("behind");
        string? held = json.Get("held") is JsonValue hv && hv.TryGetValue(out bool hb) ? (hb ? "held" : "") : json.Str("held");
        return new HermesUpdateCheck
        {
            Behind = behind,
            UpdateAvailable = json.Bool("update_available") ?? (behind ?? 0) != 0,
            CanApply = json.Bool("can_apply") ?? false,
            Message = NonEmpty(json.Get("message") is JsonValue mv && mv.TryGetValue(out string? m) ? m : null),
            CurrentVersion = NonEmpty(json.Str("current_version")),
            Command = NonEmpty(json.Get("update_command") is JsonValue uv && uv.TryGetValue(out string? u) ? u : null),
            InstallMethod = NonEmpty(json.Get("install_method") is JsonValue iv && iv.TryGetValue(out string? i) ? i : null),
            Channel = NonEmpty(json.Get("channel") is JsonValue chv && chv.TryGetValue(out string? ch) ? ch : null),
            SourceVersion = NonEmpty(json.Str("source_version")),
            Held = NonEmpty(held),
            RollbackTo = NonEmpty(json.Str("rollback_to")),
            Commits = [.. (json.Arr("commits") ?? []).Select(HermesUpdateCommit.Parse).OfType<HermesUpdateCommit>()],
        };
    }

    /// The row's value: "Up to Date", "3 Updates Available", "Update Available", "Couldn’t Check".
    public string Words
    {
        get
        {
            if (Behind is not { } behind) return UpdateAvailable ? "Update Available" : "Couldn’t Check";
            if (behind == 0 && !UpdateAvailable) return "Up to Date";
            if (behind > 0) return behind == 1 ? "1 Update Available" : $"{behind} Updates Available";
            return "Update Available";
        }
    }

    public bool CanUpdateNow => CanApply && UpdateAvailable;

    /// The gateway answered but its check didn't run: "Couldn’t Check", with Check Again.
    public bool CouldNotCheck => Behind == null && !UpdateAvailable;

    /// "0.23.0 Available · 3 changes" when the check names the release (CommandCenterSystem.updateWords).
    public string UpdateWords
    {
        get
        {
            if (!UpdateAvailable || (SourceVersion ?? RollbackTo) is not { } to) return Words;
            var release = $"{HermesUpdateEnd.Normalized(to)} Available";
            if (Behind is not > 0) return release;
            return release + " · " + (Behind == 1 ? "1 change" : $"{Behind} changes");
        }
    }
}

// ------------------------------------------------------------------ logs

public enum LogLevelFilter { All, Errors, Warnings }

public static class LogLevels
{
    public static readonly LogLevelFilter[] Cases = [LogLevelFilter.All, LogLevelFilter.Errors, LogLevelFilter.Warnings];
    public static string Title(this LogLevelFilter l) => l switch { LogLevelFilter.Errors => "Errors", LogLevelFilter.Warnings => "Warnings", _ => "All" };
    /// `level=` on `GET /api/logs` (a minimum: WARNING also lists errors); null for All.
    public static string? Query(this LogLevelFilter l) => l switch { LogLevelFilter.Errors => "ERROR", LogLevelFilter.Warnings => "WARNING", _ => null };
}

public enum LogLineLevel { None, Error, Warning }

public static class LogLines
{
    /// `{"file","lines":[…]}`: each line without its line ending; anything that is not text is skipped.
    public static List<string> Parse(JsonNode? json) =>
        [.. (json.Arr("lines") ?? []).Select(v => v is JsonValue jv && jv.TryGetValue(out string? s) ? s.TrimEnd('\n', '\r') : null).OfType<string>()];

    /// The level stamped on a line ("2026-10-13 09:15:02,123 ERROR gateway.run: …"), read from its first 60 characters.
    public static LogLineLevel Level(string line)
    {
        var head = line.Length > 60 ? line[..60] : line;
        foreach (var word in head.Split(' ', 5, StringSplitOptions.RemoveEmptyEntries).Take(4))
        {
            switch (word)
            {
                case "ERROR" or "CRITICAL" or "[ERROR]" or "[CRITICAL]": return LogLineLevel.Error;
                case "WARNING" or "WARN" or "[WARNING]" or "[WARN]": return LogLineLevel.Warning;
            }
        }
        return LogLineLevel.None;
    }

    /// Audit 863 (08d-5): the line over lines a refresh couldn't replace, naming their level when another was picked.
    public static string RefreshFailedText(LogLevelFilter shown, LogLevelFilter asked) =>
        shown == asked ? "Couldn’t refresh. Showing the last lines."
            : $"Couldn’t load {asked.Title().ToLowerInvariant()}. Showing {(shown == LogLevelFilter.All ? "every level" : shown.Title().ToLowerInvariant() + " only")}.";

    /// Audit 863 (08d-11): under an empty list, that there are none.
    public static string EmptyText(LogLevelFilter shown) =>
        shown == LogLevelFilter.All ? "The gateway’s log is empty." : $"The gateway’s recent log has no {shown.Title().ToLowerInvariant()}.";

    public static string EmptyTitle(LogLevelFilter shown) => shown == LogLevelFilter.All ? "No Logs" : $"No {shown.Title()}";
}

// ------------------------------------------------------------------ usage

/// `GET /api/analytics/usage?days=N`.
public sealed record UsageReport
{
    public sealed record Day(string Id, DateTime Date, long Input, long Output, long Sessions) { public long Tokens => Input + Output; }
    public sealed record Model(string Id, long Tokens, long? Sessions, double? Cost);
    public sealed record Skill(string Id, long Count);

    public int PeriodDays { get; init; }
    public long? Tokens { get; init; }
    public long? Sessions { get; init; }
    public double? Cost { get; init; }
    public IReadOnlyList<Day> Daily { get; init; } = [];
    public IReadOnlyList<Model> Models { get; init; } = [];
    public IReadOnlyList<Skill> Skills { get; init; } = [];

    public static UsageReport Parse(JsonNode? json, int asked)
    {
        var totals = json.Get("totals");
        var input = totals.Int("total_input");
        var output = totals.Int("total_output");
        var cost = totals.Num("total_estimated_cost");
        var days = new HashSet<string>();
        var daily = new List<Day>();
        foreach (var row in json.Arr("daily") ?? [])
        {
            if (row.Get("day") is not JsonValue dv || !dv.TryGetValue(out string? day) || ParseDate(day) is not { } date || !days.Add(day)) continue;
            daily.Add(new Day(day, date, Math.Max(0, row.Int("input_tokens") ?? 0), Math.Max(0, row.Int("output_tokens") ?? 0),
                Math.Max(0, row.Int("sessions") ?? 0)));
        }
        daily.Sort((a, b) => a.Date.CompareTo(b.Date));
        var names = new HashSet<string>();
        var models = new List<Model>();
        foreach (var row in json.Arr("by_model") ?? [])
        {
            if (row.Get("model") is not JsonValue mv || !mv.TryGetValue(out string? name) || name.Length == 0 || !names.Add(name)) continue;
            models.Add(new Model(name, Math.Max(0, (row.Int("input_tokens") ?? 0) + (row.Int("output_tokens") ?? 0)), row.Int("sessions"),
                row.Num("estimated_cost")));
        }
        var skillNames = new HashSet<string>();
        var skills = new List<Skill>();
        foreach (var row in json.Get("skills").Arr("top_skills") ?? [])
        {
            if (row.Get("skill") is not JsonValue sv || !sv.TryGetValue(out string? name) || name.Length == 0 || !skillNames.Add(name)) continue;
            var count = row.Int("total_count") ?? (row.Int("view_count") ?? 0) + (row.Int("manage_count") ?? 0);
            skills.Add(new Skill(name, Math.Max(0, count)));
        }
        return new UsageReport
        {
            PeriodDays = (int)(json.Int("period_days") ?? asked),
            Tokens = input == null && output == null ? null : (input ?? 0) + (output ?? 0),
            Sessions = totals.Int("total_sessions"),
            Cost = cost is { } c && double.IsFinite(c) ? c : null,
            Daily = daily, Models = models, Skills = skills,
        };
    }

    /// Nobody used this gateway in the period: "No Usage Yet".
    public bool IsEmpty => Daily.All(d => d.Tokens == 0 && d.Sessions == 0) && Models.Count == 0 && (Sessions ?? 0) == 0 && (Tokens ?? 0) == 0;

    /// The screen reader's summary of the chart: "Daily tokens, 30 days. Most on October 3: 1.2M."
    public string ChartSummary(CultureInfo? culture = null)
    {
        var head = $"Daily tokens, {Daily.Count} {(Daily.Count == 1 ? "day" : "days")}";
        var peak = Daily.Count == 0 ? null : Daily.MaxBy(d => d.Tokens);
        if (peak is not { Tokens: > 0 }) return head;
        return $"{head}. Most on {peak.Date.ToString("MMMM d", culture ?? CultureInfo.CurrentCulture)}: {UsageFormat.Compact(peak.Tokens)}.";
    }

    public static DateTime? ParseDate(string day)
    {
        var head = day.Length > 10 ? day[..10] : day;
        var parts = head.Split('-', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 3 || !int.TryParse(parts[0], out var y) || !int.TryParse(parts[1], out var m) || !int.TryParse(parts[2], out var d)) return null;
        if (m is < 1 or > 12 || d is < 1 or > 31) return null;
        try { return new DateTime(y, m, Math.Min(d, DateTime.DaysInMonth(y, m))); } catch (ArgumentOutOfRangeException) { return null; }
    }

    /// The dashboard's tiles (UsageDashboard.tiles): totals with what they come to a day.
    public int DayCount => Math.Max(1, Daily.Count == 0 ? PeriodDays : Daily.Count);
    public long InputTotal => Daily.Sum(d => d.Input);
    public long OutputTotal => Daily.Sum(d => d.Output);
    public Day? Peak => Daily.Count == 0 ? null : Daily.MaxBy(d => d.Tokens) is { Tokens: > 0 } p ? p : null;
    public string? TokensNote => InputTotal + OutputTotal > 0 ? $"{UsageFormat.Compact(InputTotal)} read · {UsageFormat.Compact(OutputTotal)} written" : null;
    public string? SessionsNote => Sessions is { } s ? $"about {Math.Max(1, (long)Math.Round((double)s / DayCount, MidpointRounding.AwayFromZero))} a day" : null;
    public string? CostNote => Cost is { } c ? $"about {UsageFormat.Cost(c / DayCount)} a day" : null;
}

public static class UsageFormat
{
    /// 950 → "950", 12,340 → "12.3K", 1,234,567 → "1.2M", 2,500,000,000 → "2.5B".
    public static string Compact(long value)
    {
        double n = Math.Abs((double)value);
        var sign = value < 0 ? "-" : "";
        string Scaled(double divisor, string unit)
        {
            var v = n / divisor;
            var text = v >= 99.95 ? v.ToString("F0", CultureInfo.InvariantCulture) : v.ToString("F1", CultureInfo.InvariantCulture);
            if (text.EndsWith(".0", StringComparison.Ordinal)) text = text[..^2];
            return sign + text + unit;
        }
        if (n < 1000) return sign + ((long)n).ToString(CultureInfo.InvariantCulture);
        if (n < 999_950) return Scaled(1000, "K");
        if (n < 999_950_000) return Scaled(1_000_000, "M");
        return Scaled(1_000_000_000, "B");
    }

    public static string Compact(long? value) => value is { } v ? Compact(v) : "—";

    /// 12.3456 → "$12.35", 0.004 → "<$0.01", 0 → "$0.00", null → "—".
    public static string Cost(double? value)
    {
        if (value is not { } v || !double.IsFinite(v)) return "—";
        if (v > 0 && v < 0.01) return "<$0.01";
        if (v >= 1000) return "$" + Compact((long)Math.Round(v, MidpointRounding.AwayFromZero));
        return "$" + v.ToString("F2", CultureInfo.InvariantCulture);
    }

    public static string Sessions(long? count) => count switch
    {
        null => "—",
        1 => "1 session",
        { } c => $"{c.ToString("N0", CultureInfo.CurrentCulture)} sessions",
    };

    public static string Actions(long count) => count == 1 ? "1 action" : $"{count} actions";

    /// The list page's line under a model: "12 sessions · $1.20".
    public static string ModelLine(UsageReport.Model m) =>
        string.Join(" · ", new[] { m.Sessions is { } s ? Sessions(s) : null, m.Cost is { } c ? Cost(c) : null }.OfType<string>());

    /// The dashboard's period words: "Last 30 Days".
    public static string Period(int days) => $"Last {days} Days";

    /// Audit 863 (08d-5): the line over numbers a refresh couldn't replace.
    public static string RefreshFailedText(int shown, int asked) =>
        shown == asked ? "Couldn’t refresh. Showing the last numbers." : $"Couldn’t load {asked} days. Showing the last {shown} days.";

    public static readonly int[] Periods = [7, 30, 90];
}

// ------------------------------------------------------------------ the API

/// Status & Maintenance's routes on the gateway in use.
public sealed class CommandCenterApi(GatewaySession session)
{
    public GatewaySession Session { get; } = session;
    public GatewayActionsApi Actions => new(Session);

    public async Task<GatewayStatusReport> StatusAsync(CancellationToken ct = default) =>
        GatewayStatusReport.Parse(await Session.GetJsonAsync("/api/status", timeout: TimeSpan.FromSeconds(20), ct: ct));

    /// `GET /api/logs?file=agent&lines=200[&level=ERROR|WARNING]`.
    public static List<KeyValuePair<string, string>> LogsQuery(LogLevelFilter level, int lines = 200)
    {
        var q = new List<KeyValuePair<string, string>> { new("file", "agent"), new("lines", lines.ToString(CultureInfo.InvariantCulture)) };
        if (level.Query() is { } l) q.Add(new("level", l));
        return q;
    }

    public async Task<List<string>> LogsAsync(LogLevelFilter level, int lines = 200, CancellationToken ct = default) =>
        LogLines.Parse(await Session.GetJsonAsync("/api/logs", LogsQuery(level, lines), TimeSpan.FromSeconds(30), ct));

    public async Task<UsageReport> UsageAsync(int days, CancellationToken ct = default)
    {
        var answer = await Session.GetJsonAsync("/api/analytics/usage", [new("days", days.ToString(CultureInfo.InvariantCulture))],
            TimeSpan.FromSeconds(30), ct);
        if (answer is not JsonObject) throw InsightsWire.Unreadable(answer);
        return UsageReport.Parse(answer, days);
    }

    public async Task<HermesUpdateCheck> UpdateCheckAsync(bool force = false, CancellationToken ct = default) =>
        HermesUpdateCheck.Parse(await Session.GetJsonAsync("/api/hermes/update/check",
            force ? [new("force", "true")] : null, TimeSpan.FromSeconds(45), ct));
}

// ------------------------------------------------------------------ maintenance

/// The Maintenance section's actions (`V/app/command-center/maintenance.tsx`): the three that only read or add a file on
/// the gateway computer.
public enum MaintenanceAction { Doctor, SecurityAudit, Backup }

public static class Maintenance
{
    public static readonly MaintenanceAction[] Cases = [MaintenanceAction.Doctor, MaintenanceAction.SecurityAudit, MaintenanceAction.Backup];

    public static string Title(this MaintenanceAction a) => a switch
    {
        MaintenanceAction.Doctor => "Run Doctor", MaintenanceAction.SecurityAudit => "Security Audit", _ => "Create Backup",
    };
    public static string Detail(this MaintenanceAction a) => a switch
    {
        MaintenanceAction.Doctor => "Health-check the install, config, and providers",
        MaintenanceAction.SecurityAudit => "Scan config and skills for risky settings",
        _ => $"Zip config, memories, skills, and sessions on {HostWord.Phrase}",
    };
    public static string OutputTitle(this MaintenanceAction a) => a switch
    {
        MaintenanceAction.Doctor => "Doctor", MaintenanceAction.SecurityAudit => "Security Audit", _ => "Backup",
    };
    public static string Path(this MaintenanceAction a) => a switch
    {
        MaintenanceAction.Doctor => "/api/ops/doctor", MaintenanceAction.SecurityAudit => "/api/ops/security-audit", _ => "/api/ops/backup",
    };
    public static string ActionName(this MaintenanceAction a) => a switch
    {
        MaintenanceAction.Doctor => "doctor", MaintenanceAction.SecurityAudit => "security-audit", _ => "backup",
    };
    public static string Id(this MaintenanceAction a) => a switch
    {
        MaintenanceAction.Doctor => "doctor", MaintenanceAction.SecurityAudit => "securityAudit", _ => "backup",
    };
    /// The doctor and the backup take `{}` (every default); the audit takes no body.
    public static JsonNode? Body(this MaintenanceAction a) => a == MaintenanceAction.SecurityAudit ? null : new JsonObject();

    public static Task<string> StartAsync(this MaintenanceAction a, GatewayActionsApi api) =>
        api.StartAsync(a.Path(), null, a.ActionName(), a.Body());

    public const string RunsHere = "These run on the computer running Hermes. Nothing is sent anywhere else.";
}

/// What a row or an output page says for an action's phase.
public sealed record ActionWords(string Text, bool IsError = false, bool IsBusy = false)
{
    public static ActionWords? Update(ActionPhase phase) => phase switch
    {
        ActionPhase.IdlePhase => null,
        ActionPhase.RunningPhase => new("Updating…", IsBusy: true),
        ActionPhase.StalledPhase => new("Still updating. This page updates when your gateway is back.", IsBusy: true),
        ActionPhase.UntrackedPhase => new("Update started. This Hermes doesn’t report an update’s progress, so it can’t be followed here."),
        ActionPhase.Finished { Ok: true } => new("Hermes Updated"),
        ActionPhase.Finished => new("The update didn’t finish.", IsError: true),
        ActionPhase.Failed f => new(f.Reason, IsError: true),
        _ => null,
    };

    public static ActionWords? MaintenanceWords(ActionPhase phase) => phase switch
    {
        ActionPhase.IdlePhase => null,
        ActionPhase.RunningPhase => new("Running…", IsBusy: true),
        ActionPhase.StalledPhase => new("Still running. This page updates when your gateway answers.", IsBusy: true),
        ActionPhase.UntrackedPhase => new("Started. This Hermes doesn’t report its progress, so it can’t be followed here."),
        ActionPhase.Finished { Ok: true } => new("Finished"),
        ActionPhase.Finished => new("Finished with Problems", IsError: true),
        ActionPhase.Failed f => new(f.Reason, IsError: true),
        _ => null,
    };

    /// The last `count` lines that say something.
    public static List<string> Tail(IEnumerable<string> lines, int count = 4) =>
        [.. lines.Where(l => l.Trim().Length > 0 && !l.StartsWith("===", StringComparison.Ordinal)).TakeLast(count)];
}

/// The restart's words (App/Pages/More/Kit/GatewayRestartViews.swift).
public static class GatewayRestartWords
{
    public const string ConfirmTitle = "Restart Your Gateway?";
    public const string ConfirmMessage = "Bots stop for a moment and running replies are interrupted.";
    public const string ConfirmAction = "Restart";
    public const string UntrackedText = "Restart sent. This Hermes doesn’t report a restart’s progress, so it can’t be followed here.";

    public static ActionWords? Words(ActionPhase phase) => phase switch
    {
        ActionPhase.IdlePhase => null,
        ActionPhase.RunningPhase => new("Restarting…", IsBusy: true),
        ActionPhase.StalledPhase => new("Still restarting. This page updates when your gateway is back.", IsBusy: true),
        ActionPhase.UntrackedPhase => new(UntrackedText),
        ActionPhase.Finished { Ok: true } => new("Gateway Restarted"),
        ActionPhase.Finished f => new(f.LastLine ?? "The gateway didn’t restart.", IsError: true),
        ActionPhase.Failed f => new(f.Reason, IsError: true),
        _ => null,
    };
}
