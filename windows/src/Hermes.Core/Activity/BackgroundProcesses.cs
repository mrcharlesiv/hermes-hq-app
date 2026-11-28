using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Activity;

// Running background commands (`process.list`, `process.kill`), subagent roster/tail reads, and working-ledger
// snapshots. Port of HermesKit/Chat/ChatGatewayExtras.swift (`BackgroundProcess`) and LiveChatSession+Extras.swift
// (`runningCommands`, `stopCommand`). Old gateways without a method answer -32601 and the feature hides cleanly.

/// One of a chat's background processes as `process.list` reports it (HermesKit/Chat/ChatGatewayExtras.swift).
public sealed record BackgroundProcess
{
    private static readonly Regex AnsiEscape = new(
        @"\x1B(?:\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])",
        RegexOptions.Compiled);

    private static readonly string[] IsoTimestampFormats =
    [
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK",
        "yyyy-MM-dd'T'HH:mm:ssK",
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFF",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss.FFFFFF",
        "yyyy-MM-dd HH:mm:ss.SSS",
        "yyyy-MM-dd HH:mm:ss",
    ];

    private static readonly double MinUnixTimeMilliseconds = DateTimeOffset.MinValue.ToUnixTimeMilliseconds();
    private static readonly double MaxUnixTimeMilliseconds = DateTimeOffset.MaxValue.ToUnixTimeMilliseconds();

    private IReadOnlyList<string> _watchPatterns = ValueList<string>.Empty;

    public BackgroundProcess(
        string Id,
        string Command,
        string Status,
        double? UptimeSeconds = null,
        int? ExitCode = null,
        string? OutputTail = null,
        string? Cwd = null,
        DateTimeOffset? StartedAt = null,
        int? Pid = null,
        IReadOnlyList<string>? WatchPatterns = null,
        string? WatchHit = null,
        DateTimeOffset? LastOutputAt = null)
    {
        this.Id = Id;
        this.Command = Command;
        this.Status = Status;
        this.UptimeSeconds = UptimeSeconds;
        this.ExitCode = ExitCode;
        this.OutputTail = OutputTail;
        this.Cwd = Cwd;
        this.StartedAt = StartedAt;
        this.Pid = Pid;
        this.WatchPatterns = WatchPatterns ?? ValueList<string>.Empty;
        this.WatchHit = WatchHit;
        this.LastOutputAt = LastOutputAt;
    }

    public BackgroundProcess() : this("", "", "running") { }

    public string Id { get; init; }
    public string Command { get; init; }
    public string Status { get; init; }
    public double? UptimeSeconds { get; init; }
    public int? ExitCode { get; init; }
    public string? OutputTail { get; init; }
    /// The folder it runs in (`process.list`'s `cwd`), for the row's detail when its command has no `cd`.
    public string? Cwd { get; init; }
    /// When the process started (`process.list`'s `started_at`).
    public DateTimeOffset? StartedAt { get; init; }
    /// OS process id when `process.list` reports it.
    public int? Pid { get; init; }
    /// Patterns the gateway is watching this job's output for (`watch_patterns`).
    public IReadOnlyList<string> WatchPatterns
    {
        get => _watchPatterns;
        init => _watchPatterns = value is null ? ValueList<string>.Empty
            : value is ValueList<string> vl ? vl
            : new ValueList<string>(value);
    }
    /// The watch pattern that matched, if any (`watch_hit`).
    public string? WatchHit { get; init; }
    /// When the job last printed output, if the gateway reports `last_output_at`.
    public DateTimeOffset? LastOutputAt { get; init; }

    /// The bot's own sentence before the call that started it (`BackgroundJobWords.BotWords`), filled from the transcript.
    public string? BotWords { get; init; }
    /// The unclipped version of `BotWords` for the detail view's headline (`ba08fcdd4`).
    public string? FullBotWords { get; init; }
    /// Fuller context from the bot's paragraph before starting the job, when longer than `FullBotWords`.
    public string? BotNote { get; init; }
    /// The full command recovered from the chat's `terminal` tool call when `process.list` clipped it.
    public string? FullCommand { get; init; }

    public bool IsRunning => string.Equals(Status, "running", StringComparison.Ordinal);

    /// The fullest command available: the transcript's untruncated command when recovered, else `process.list`'s.
    public string EffectiveCommand => FullCommand ?? Command;

    /// The row's name: the bot's `# comment`, its own words, an agent's prompt, or the program and folder.
    public string Headline => BackgroundJobWords.Headline(EffectiveCommand, BotWords);

    /// The detail page's unclipped name: never cut short at the list row's 80/90-character cap (`ba08fcdd4`).
    public string FullHeadline => BackgroundJobWords.FullHeadline(EffectiveCommand, FullBotWords, BotWords);

    /// Who runs it and where ("Claude Code · goals-2"); null when the name says it all.
    public string? DetailLine => BackgroundJobWords.Detail(EffectiveCommand, Cwd, Headline);

    /// The job's name (`BackgroundTaskText.Title`), with "background process" mapped to "Background command".
    public string Title
    {
        get
        {
            var name = BackgroundTaskText.Title(EffectiveCommand);
            return name == "background process" ? "Background command" : name;
        }
    }

    /// The row's line while the job has printed nothing: where its output goes when it writes to a file.
    public string QuietLine => BackgroundTaskText.QuietLine(EffectiveCommand);

    /// "Running · 3m" (or "Running" while the time is unknown; "Exited (code 1)" / "Exited" when exited).
    public string Detail
    {
        get
        {
            if (!IsRunning) return ExitCode is { } code ? $"Exited (code {code})" : "Exited";
            return UptimeSeconds is { } up ? $"Running · {FormatDuration((int)up)}" : "Running";
        }
    }

    /// `OutputTail` with ANSI escape sequences stripped, carriage-return overwrites collapsed, and outer blank lines trimmed.
    public string CleanOutput => CleanTail(OutputTail);

    /// Non-empty trimmed lines from `CleanOutput`, in order.
    public IReadOnlyList<string> OutputLines
    {
        get
        {
            var cleaned = CleanOutput;
            if (cleaned.Length == 0) return Array.Empty<string>();
            var lines = new List<string>();
            foreach (var raw in cleaned.Split('\n'))
            {
                var trimmed = raw.Trim(' ', '\t');
                if (trimmed.Length > 0) lines.Add(trimmed);
            }
            return lines;
        }
    }

    /// The newest line it printed (for the shelf's row), at most 160 characters; "" when it printed none.
    public string LastLine
    {
        get
        {
            var lines = OutputLines;
            if (lines.Count == 0) return "";
            return CapLine(lines[^1]);
        }
    }

    /// The last two lines it printed, each at most 160 characters.
    public string TailLines
    {
        get
        {
            var lines = OutputLines;
            if (lines.Count == 0) return "";
            var start = Math.Max(0, lines.Count - 2);
            var take = new string[lines.Count - start];
            for (var i = 0; i < take.Length; i++) take[i] = CapLine(lines[start + i]);
            return string.Join("\n", take);
        }
    }

    /// Up to two non-empty lines immediately before `LastLine`, for the list row's multi-line preview.
    public IReadOnlyList<string> EarlierPreviewLines
    {
        get
        {
            var lines = OutputLines;
            if (lines.Count <= 1) return Array.Empty<string>();
            var end = lines.Count - 1;
            var start = Math.Max(0, end - 2);
            var result = new string[end - start];
            for (var i = 0; i < result.Length; i++) result[i] = CapLine(lines[start + i]);
            return result;
        }
    }

    /// The newest output line, else an honest quiet line ("No output for 1h 22m", "Quiet until it's done", …).
    public string StatusLine => LastLine.Length == 0
        ? BackgroundJobWords.QuietLine(EffectiveCommand, UptimeSeconds is { } up ? (int)up : null)
        : LastLine;

    /// Single-job shelf chip words: "Background task · 6m" when uptime is known, else "Background task".
    public string ChipWords => UptimeSeconds is { } up
        ? $"Background task · {FormatDuration((int)up)}"
        : "Background task";

    /// Short freshness phrase for when output last changed ("Updated just now", "Updated 2m ago"); "" if unknown.
    public string FreshnessWords(DateTimeOffset now) =>
        LastOutputAt is { } last ? FormatFreshness(last, now) : "";

    /// Live elapsed seconds: `UptimeSeconds` counted forward locally from `observedAt`, else `StartedAt` fallback.
    public int? ElapsedSeconds(DateTimeOffset? observedAt, DateTimeOffset now)
    {
        if (UptimeSeconds is { } uptime)
        {
            var baseSec = Math.Max(0, (int)uptime);
            if (observedAt is not { } obs) return baseSec;
            var delta = Math.Max(0, (int)Math.Floor((now - obs).TotalSeconds));
            return Math.Max(0, baseSec + delta);
        }
        if (StartedAt is { } started)
            return Math.Max(0, (int)Math.Floor((now - started).TotalSeconds));
        return null;
    }

    /// Double-epoch overload matching Swift `elapsedSeconds(observedAt:now:)`.
    public int? ElapsedSeconds(double? observedAtUnixSeconds, double nowUnixSeconds)
    {
        if (UptimeSeconds is { } uptime)
        {
            var baseSec = Math.Max(0, (int)uptime);
            if (observedAtUnixSeconds is not { } obs) return baseSec;
            var delta = Math.Max(0, (int)Math.Floor(nowUnixSeconds - obs));
            return Math.Max(0, baseSec + delta);
        }
        if (StartedAt is { } started)
        {
            var startedSec = started.ToUnixTimeMilliseconds() / 1000.0;
            return Math.Max(0, (int)Math.Floor(nowUnixSeconds - startedSec));
        }
        return null;
    }

    /// When this job started: `StartedAt` when reported, else derived from `UptimeSeconds` at `observedAt`.
    public DateTimeOffset? StartDate(DateTimeOffset? observedAt)
    {
        if (StartedAt is { } started) return started;
        if (UptimeSeconds is { } uptime && observedAt is { } obs)
            return obs.AddSeconds(-uptime);
        return null;
    }

    /// Returns a copy enriched with bot words, full bot words, bot note, and full command from the chat's transcript.
    public BackgroundProcess WithTranscriptMatch(IReadOnlyList<ChatMessage> messages)
    {
        if (BackgroundJobWords.Match(Command, messages) is not { } matched) return this;
        return this with
        {
            BotWords = matched.BotWords,
            FullBotWords = matched.FullBotWords,
            BotNote = matched.BotNote,
            FullCommand = matched.FullCommand,
        };
    }

    /// Shelf chip words for a list of running jobs: null with none, "Background task · 6m" for one, "2 background tasks" for more.
    public static string? FormatChipWords(IReadOnlyList<BackgroundProcess> running) => running.Count switch
    {
        0 => null,
        1 => running[0].ChipWords,
        _ => $"{running.Count} background tasks",
    };

    /// Short freshness phrase for when output last changed ("Updated just now", "Updated 2m ago").
    public static string FormatFreshness(DateTimeOffset since, DateTimeOffset now)
    {
        var age = Math.Max(0, (int)Math.Floor((now - since).TotalSeconds));
        return age < 5 ? "Updated just now" : $"Updated {FormatDuration(age)} ago";
    }

    public static string FormatFreshness(double sinceUnixSeconds, double nowUnixSeconds)
    {
        var age = Math.Max(0, (int)Math.Floor(nowUnixSeconds - sinceUnixSeconds));
        return age < 5 ? "Updated just now" : $"Updated {FormatDuration(age)} ago";
    }

    public static string FormatDuration(int seconds)
    {
        var s = Math.Max(0, seconds);
        if (s < 60) return $"{s}s";
        if (s < 3600) return $"{s / 60}m";
        var m = (s % 3600) / 60;
        return m == 0 ? $"{s / 3600}h" : $"{s / 3600}h {m}m";
    }

    /// Strips ANSI CSI/OSC escape sequences, normalizes progress-bar `\r` overwrites, and trims outer blank lines.
    public static string CleanTail(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return "";
        var text = raw.Replace("\r\n", "\n", StringComparison.Ordinal);
        if (text.Contains('\x1B')) text = AnsiEscape.Replace(text, "");
        if (text.Contains('\r'))
        {
            var rawLines = text.Split('\n');
            for (var i = 0; i < rawLines.Length; i++)
            {
                if (!rawLines[i].Contains('\r')) continue;
                var parts = rawLines[i].Split('\r', StringSplitOptions.RemoveEmptyEntries);
                rawLines[i] = parts.Length > 0 ? parts[^1] : "";
            }
            text = string.Join("\n", rawLines);
        }
        var lines = text.Split('\n');
        var start = 0;
        var end = lines.Length - 1;
        while (start <= end && string.IsNullOrWhiteSpace(lines[start])) start++;
        while (end >= start && string.IsNullOrWhiteSpace(lines[end])) end--;
        if (start > end) return "";
        return string.Join("\n", lines[start..(end + 1)]);
    }

    /// Parses a numeric Unix epoch (seconds) or ISO 8601 date-time string (with or without timezone and fractional seconds).
    public static DateTimeOffset? ParseTimestamp(JsonNode? value)
    {
        if (value is null) return null;
        if (ActivityJson.Num(value) is { } n && double.IsFinite(n) && n > 0)
        {
            var ms = n * 1000.0;
            if (!double.IsFinite(ms) || ms < MinUnixTimeMilliseconds || ms > MaxUnixTimeMilliseconds) return null;
            return DateTimeOffset.FromUnixTimeMilliseconds((long)ms);
        }
        var raw = ActivityJson.StrOrNull(value)?.Trim();
        if (string.IsNullOrEmpty(raw)) return null;
        if (DateTimeOffset.TryParseExact(raw, IsoTimestampFormats, CultureInfo.InvariantCulture,
                DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeLocal, out var exact))
            return exact;
        if (raw.Contains('-') && raw.Contains(':')
            && DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture,
                DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeLocal, out var parsed))
            return parsed;
        return null;
    }

    /// Decodes `process.list`'s `processes` array; rows without an id are left out.
    public static IReadOnlyList<BackgroundProcess> ParseList(JsonNode? json)
    {
        var array = json.Get("processes") as JsonArray ?? json as JsonArray;
        if (array is null) return Array.Empty<BackgroundProcess>();
        var list = new List<BackgroundProcess>(array.Count);
        foreach (var entry in array)
        {
            if (entry is null) continue;
            var id = entry.Text("session_id") ?? entry.Text("id");
            if (id is null) continue;
            var uptime = ActivityJson.Num(entry.Get("uptime_seconds")) is { } u && double.IsFinite(u) && u >= 0 ? u : (double?)null;
            var patterns = new List<string>();
            if (entry.Get("watch_patterns") is JsonArray wp)
            {
                foreach (var item in wp)
                {
                    var s = ActivityJson.StrOrNull(item)?.Trim();
                    if (!string.IsNullOrEmpty(s)) patterns.Add(s);
                }
            }
            var tail = ActivityJson.StrOrNull(entry.Get("output_tail"))
                ?? ActivityJson.StrOrNull(entry.Get("output_preview"))
                ?? "";
            list.Add(new BackgroundProcess(
                Id: id,
                Command: ActivityJson.StrOrNull(entry.Get("command")) ?? "",
                Status: ActivityJson.StrOrNull(entry.Get("status")) ?? "running",
                UptimeSeconds: uptime,
                ExitCode: ActivityJson.Int(entry.Get("exit_code")),
                OutputTail: tail,
                Cwd: entry.Text("cwd"),
                StartedAt: ParseTimestamp(entry.Get("started_at")),
                Pid: ActivityJson.Int(entry.Get("pid")),
                WatchPatterns: patterns,
                WatchHit: entry.Text("watch_hit"),
                LastOutputAt: ParseTimestamp(entry.Get("last_output_at"))));
        }
        return list;
    }

    private static string CapLine(string line) => line.Length > 160 ? line[..159] + "…" : line;
}

/// One active-turn row returned by `/api/plugins/hermes-hq-push/sessions/working` or `serve/working`.
public sealed record WorkingLedgerEntry(string SessionId, string Profile, string? Status = null, string? Kind = null);

/// Snapshot returned by `GET /api/plugins/hermes-hq-push/sessions/working` or `serve/working`.
public sealed record WorkingLedgerSnapshot(
    bool FromServe,
    IReadOnlySet<string> SessionIds,
    IReadOnlyList<WorkingLedgerEntry> Entries)
{
    public static readonly WorkingLedgerSnapshot Empty = new(false, new HashSet<string>(StringComparer.Ordinal), Array.Empty<WorkingLedgerEntry>());

    public IReadOnlySet<string> SessionIdsForProfile(string? profile)
    {
        var want = string.IsNullOrEmpty(profile) ? "default" : profile;
        var set = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in Entries)
        {
            if (entry.Profile.Length == 0 || string.Equals(entry.Profile, want, StringComparison.Ordinal))
                set.Add(entry.SessionId);
        }
        return set;
    }

    public static WorkingLedgerSnapshot Parse(JsonNode? json, bool fromServe = false)
    {
        if (json.Get("sessions") is not JsonArray rows) return new WorkingLedgerSnapshot(fromServe, new HashSet<string>(StringComparer.Ordinal), Array.Empty<WorkingLedgerEntry>());
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var entries = new List<WorkingLedgerEntry>(rows.Count);
        foreach (var row in rows)
        {
            if (row is null) continue;
            var id = row.Text("id") ?? row.Text("session_id");
            if (id is null) continue;
            var profile = row.Text("profile") ?? "";
            ids.Add(id);
            entries.Add(new WorkingLedgerEntry(id, profile, row.Text("status"), row.Text("kind")));
        }
        return new WorkingLedgerSnapshot(fromServe, ids, entries);
    }
}

/// Gateway RPC & REST helpers for background processes, subagent roster/tail, agents list, and working ledger.
public static class BackgroundProcessesApi
{
    public static readonly TimeSpan ProcessListTimeout = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan ProcessKillTimeout = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan RosterTimeout = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan LedgerTimeout = TimeSpan.FromSeconds(10);

    /// Strict params for `process.list`: `{session_id, profile?}`.
    public static JsonObject ProcessListParams(string sessionId, string? profile = null) =>
        ActivityStore.Params(sessionId, profile);

    /// Strict params for `process.kill`: `{session_id, profile?, process_id}`.
    public static JsonObject ProcessKillParams(string sessionId, string processId, string? profile = null) =>
        ActivityStore.Params(sessionId, profile, ("process_id", processId));

    /// Strict params for profile-scoped RPCs (`subagent.roster`, `agents.list`): `{}` for default/empty, else `{profile}`.
    public static JsonObject ProfileParams(string? profile) =>
        string.IsNullOrEmpty(profile) || string.Equals(profile, "default", StringComparison.Ordinal)
            ? new JsonObject()
            : new JsonObject { ["profile"] = profile };

    /// Calls RPC `process.list` `{session_id, profile?}`. Returns `null` when the gateway answers `-32601`
    /// (method not found) so the UI hides Running Commands cleanly.
    public static async Task<IReadOnlyList<BackgroundProcess>?> ListProcessesAsync(
        HermesClient client, string sessionId, string? profile = null, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(sessionId)) return Array.Empty<BackgroundProcess>();
        try
        {
            var answer = await client.Rpc.RequestAsync("process.list", ProcessListParams(sessionId, profile), ProcessListTimeout, ct);
            return BackgroundProcess.ParseList(answer);
        }
        catch (GatewayException e) when (IsMethodNotFound(e))
        {
            return null;
        }
    }

    /// Calls RPC `process.kill` `{session_id, profile?, process_id}`. Returns `false` when unsupported (`-32601`)
    /// or when the gateway explicitly reports the process was not found/killed; `true` when accepted.
    public static async Task<bool> KillProcessAsync(
        HermesClient client, string sessionId, string processId, string? profile = null, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(sessionId) || string.IsNullOrWhiteSpace(processId)) return false;
        try
        {
            var answer = await client.Rpc.RequestAsync("process.kill", ProcessKillParams(sessionId, processId, profile), ProcessKillTimeout, ct);
            if (answer.Bool("ok") == false || answer.Bool("killed") == false) return false;
            if (string.Equals(answer.Text("status"), "not_found", StringComparison.OrdinalIgnoreCase)) return false;
            return true;
        }
        catch (GatewayException e) when (IsMethodNotFound(e))
        {
            return false;
        }
    }

    /// Calls RPC `subagent.roster` (`{}` for default profile, else `{profile}`). Returns `null` on `-32601`.
    public static async Task<JsonNode?> ReadSubagentRosterAsync(
        HermesClient client, string? profile = null, CancellationToken ct = default)
    {
        try
        {
            return await client.Rpc.RequestAsync("subagent.roster", ProfileParams(profile), RosterTimeout, ct);
        }
        catch (GatewayException e) when (IsMethodNotFound(e))
        {
            return null;
        }
    }

    /// Calls RPC `agents.list` (`{}` for default profile, else `{profile}`). Returns `null` on `-32601`.
    public static async Task<JsonNode?> ReadAgentsListAsync(
        HermesClient client, string? profile = null, CancellationToken ct = default)
    {
        try
        {
            return await client.Rpc.RequestAsync("agents.list", ProfileParams(profile), ActivityStore.ReadTimeout, ct);
        }
        catch (GatewayException e) when (IsMethodNotFound(e))
        {
            return null;
        }
    }

    /// Calls RPC `subagent.tail` `{session_id, profile?, subagent_id}` and parses its steps, files, and output.
    /// Returns `null` when unsupported (`-32601`).
    public static async Task<HelperTailReport?> ReadSubagentTailAsync(
        HermesClient client, string sessionId, string childId, string? profile = null, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(sessionId) || string.IsNullOrWhiteSpace(childId)) return null;
        var (method, parameters) = ActivityStore.SubagentTailRequest(sessionId, profile, childId);
        try
        {
            var answer = await client.Rpc.RequestAsync(method, parameters, ActivityStore.ReadTimeout, ct);
            return HelperTailReport.Parse(childId, answer);
        }
        catch (GatewayException e) when (IsMethodNotFound(e))
        {
            return null;
        }
    }

    /// Calls `GET /api/plugins/hermes-hq-push/sessions/working` (or `serve/working` when `serve` is true).
    /// Returns `null` when the route responds 404 (older add-on) or 503 (outside serving process).
    public static async Task<WorkingLedgerSnapshot?> ReadWorkingLedgerAsync(
        HermesClient client, bool serve = false, CancellationToken ct = default)
    {
        var path = serve ? WorkingLedgerWatch.ServePath : WorkingLedgerWatch.LedgerPath;
        try
        {
            var json = await client.Session.GetJsonAsync(path, timeout: LedgerTimeout, ct: ct);
            return WorkingLedgerSnapshot.Parse(json, fromServe: serve);
        }
        catch (GatewayException e) when (e.Status is 404 or 503)
        {
            return null;
        }
    }

    internal static bool IsMethodNotFound(GatewayException e) =>
        e.RpcCode == -32601 || ActivityStore.IsMethodNotFound((int)e.RpcCode, e.Message);
}
