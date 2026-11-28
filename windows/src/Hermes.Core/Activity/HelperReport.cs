using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Activity;

// Port of HermesKit/Activity/HelperReport.swift + consolidated helper status summary from App/Chat/HelperStatusRows.swift
// + `HelperTailReport` steps/files/output model parsed from `subagent.tail`.

/// Ownership hints retained before hydration removes the async envelope and batch headings (HermesKit/Activity/HelperReport.swift).
public sealed record HelperReport(string? DelegationId, ValueList<HelperReport.TaskItem> Tasks)
{
    public sealed record TaskItem(string Goal, SubagentStatus Status);

    private static readonly Regex DelegationRx = new(
        @"^\[ASYNC DELEGATION[^\]\n]*[—–-]\s*(deleg_[A-Za-z0-9_-]+)\]",
        RegexOptions.Compiled);

    /// Status is the first word: the gateway follows it with call count and duration
    /// (`(status=completed, api_calls=34, 1192.42s)`), and a cut-short run adds a TRUNCATED note.
    private static readonly Regex BatchRx = new(
        @"^--- [✓✗⚠] TASK \d+/\d+: (.+?) {2}\(status=([A-Za-z_]+)[^\n]*\) ---\r?$",
        RegexOptions.Compiled | RegexOptions.Multiline);

    private static readonly Regex GoalRx = new(
        @"^Original goal: *(.+?)\r?$",
        RegexOptions.Compiled | RegexOptions.Multiline);

    private static readonly Regex StateRx = new(
        @"^Status: *([A-Za-z_]+)",
        RegexOptions.Compiled | RegexOptions.Multiline);

    public static HelperReport? Parse(string? content)
    {
        if (string.IsNullOrEmpty(content) || !content.StartsWith("[ASYNC DELEGATION", StringComparison.Ordinal))
            return null;

        var idMatch = DelegationRx.Match(content);
        var id = idMatch.Success ? idMatch.Groups[1].Value : null;
        var tasks = new List<TaskItem>();

        if (content.StartsWith("[ASYNC DELEGATION BATCH", StringComparison.Ordinal))
        {
            foreach (Match m in BatchRx.Matches(content))
            {
                if (!m.Success) continue;
                tasks.Add(new TaskItem(m.Groups[1].Value, ParseStatus(m.Groups[2].Value)));
                if (tasks.Count >= 16) break;
            }
        }
        else
        {
            var goalMatch = GoalRx.Match(content);
            if (goalMatch.Success)
            {
                var stateMatch = StateRx.Match(content);
                var rawState = stateMatch.Success ? stateMatch.Groups[1].Value : "completed";
                tasks.Add(new TaskItem(goalMatch.Groups[1].Value, ParseStatus(rawState)));
            }
        }

        if (tasks.Count == 0 && id is null) return null;
        return new HelperReport(id, new ValueList<TaskItem>(tasks.Take(16)));
    }

    public JsonObject ToJson()
    {
        var array = new JsonArray();
        foreach (var t in Tasks)
            array.Add(new JsonObject { ["goal"] = t.Goal, ["status"] = t.Status.RawValue() });
        return new JsonObject
        {
            ["delegation"] = DelegationId is null ? null : JsonValue.Create(DelegationId),
            ["tasks"] = array,
        };
    }

    public static HelperReport? FromJson(JsonNode? json)
    {
        var obj = ActivityJson.Object(json);
        if (obj.Count == 0) return null;
        var delegation = obj.Text("delegation");
        var tasks = new List<TaskItem>();
        if (obj["tasks"] is JsonArray arr)
        {
            foreach (var item in arr.Take(16))
            {
                var fields = ActivityJson.Object(item);
                var goal = ActivityJson.StrOrNull(fields["goal"]);
                var rawStatus = ActivityJson.StrOrNull(fields["status"]);
                if (goal is null || rawStatus is null || ParseWireStatus(rawStatus) is not { } status) continue;
                tasks.Add(new TaskItem(goal, status));
            }
        }
        if (delegation is null && tasks.Count == 0) return null;
        return new HelperReport(delegation, new ValueList<TaskItem>(tasks));
    }

    /// Consolidated helper status title (App/Chat/HelperStatusRows.swift `Group.title`):
    /// e.g. `"2 helpers working · 1 queued · 3 done"`, `"1 helper failed"`.
    public static string SummarizeStatus(IEnumerable<SubagentProgress> helpers) =>
        SummarizeStatuses(helpers.Select(h => h.Status));

    public static string SummarizeStatuses(IEnumerable<SubagentStatus> statuses)
    {
        int working = 0, queued = 0, done = 0, failed = 0, stopped = 0, dispatched = 0;
        foreach (var status in statuses)
        {
            switch (status)
            {
                case SubagentStatus.Running: working++; break;
                case SubagentStatus.Queued: queued++; break;
                case SubagentStatus.Completed: done++; break;
                case SubagentStatus.Failed: failed++; break;
                case SubagentStatus.Interrupted: stopped++; break;
                default: dispatched++; break;
            }
        }
        var words = new List<string>(6);
        void Add(int count, string state)
        {
            if (count <= 0) return;
            var noun = words.Count == 0 ? (count == 1 ? " helper" : " helpers") : "";
            words.Add($"{count}{noun} {state}");
        }
        Add(working, "working");
        Add(queued, "queued");
        Add(done, "done");
        Add(failed, "failed");
        Add(stopped, "stopped");
        Add(dispatched, "dispatched");
        return string.Join(" · ", words);
    }

    private static SubagentStatus ParseStatus(string value) => value.ToLowerInvariant() switch
    {
        "completed" or "ok" or "success" => SubagentStatus.Completed,
        "failed" or "error" or "rejected" or "timeout" or "timed_out" or "stalled" => SubagentStatus.Failed,
        "cancelled" or "canceled" or "interrupted" or "incomplete" => SubagentStatus.Interrupted,
        _ => SubagentStatus.Dispatched,
    };

    private static SubagentStatus? ParseWireStatus(string raw) => raw switch
    {
        "completed" => SubagentStatus.Completed,
        "failed" => SubagentStatus.Failed,
        "interrupted" => SubagentStatus.Interrupted,
        "queued" => SubagentStatus.Queued,
        "running" => SubagentStatus.Running,
        "dispatched" => SubagentStatus.Dispatched,
        _ => null,
    };
}

/// One step entry in a `HelperTailReport` (parsed from `subagent.tail` or projected from `SubagentProgress.Stream`).
public sealed record HelperTailStep(
    string Text,
    SubagentStreamKind Kind = SubagentStreamKind.Progress,
    double? At = null,
    bool IsError = false);

/// One file touched by a helper (written or read).
public sealed record HelperTailFile(string Path, bool Written);

/// Parsed `subagent.tail` detail payload: steps, files, summary, and full output text.
public sealed record HelperTailReport(
    string ChildId,
    bool Available,
    string Output,
    bool Truncated,
    ValueList<HelperTailStep> Steps,
    ValueList<HelperTailFile> Files,
    string? Summary = null)
{
    public SubagentTail ToSubagentTail() => new(Available, Output, Truncated);

    /// Parses a `subagent.tail` JSON response leniently (`{available, text, truncated}` plus optional `steps`/`stream`,
    /// `files`/`files_written`/`files_read`, and `summary`).
    public static HelperTailReport Parse(string childId, JsonNode? result)
    {
        var available = ActivityJson.IsBool(result.Get("available"), true);
        var rawOutput = ActivityJson.StrOrNull(result.Get("text"))
            ?? ActivityJson.StrOrNull(result.Get("output"))
            ?? "";
        var truncated = ActivityJson.IsBool(result.Get("truncated"), true);
        var summary = result.Text("summary");

        var steps = ParseSteps(result.Get("steps") ?? result.Get("stream"));
        var files = ParseFiles(result);

        return new HelperTailReport(
            ChildId: childId,
            Available: available,
            Output: BackgroundProcess.CleanTail(rawOutput),
            Truncated: truncated,
            Steps: new ValueList<HelperTailStep>(steps),
            Files: new ValueList<HelperTailFile>(files),
            Summary: summary);
    }

    /// Combines a chat's `SubagentProgress` snapshot with an optional `subagent.tail` response so the detail dialog
    /// always shows steps, files, summary, and output even when `subagent.tail` only returned text or was offline.
    public static HelperTailReport Combine(SubagentProgress child, HelperTailReport? tail)
    {
        var steps = tail is { Steps.Count: > 0 }
            ? tail.Steps
            : new ValueList<HelperTailStep>(child.Stream.Select(e => new HelperTailStep(e.Text, e.Kind, e.At, e.IsError)));

        ValueList<HelperTailFile> files;
        if (tail is { Files.Count: > 0 })
        {
            files = tail.Files;
        }
        else
        {
            var combinedFiles = new List<HelperTailFile>(child.FilesWritten.Count + child.FilesRead.Count);
            foreach (var p in child.FilesWritten) combinedFiles.Add(new HelperTailFile(p, Written: true));
            foreach (var p in child.FilesRead) combinedFiles.Add(new HelperTailFile(p, Written: false));
            files = new ValueList<HelperTailFile>(combinedFiles);
        }

        var output = tail is { Available: true, Output.Length: > 0 } ? tail.Output : "";
        var summary = !string.IsNullOrEmpty(tail?.Summary) ? tail.Summary : child.Summary;

        return new HelperTailReport(
            ChildId: child.Id,
            Available: tail?.Available ?? false,
            Output: output,
            Truncated: tail?.Truncated ?? false,
            Steps: steps,
            Files: files,
            Summary: summary);
    }

    private static List<HelperTailStep> ParseSteps(JsonNode? node)
    {
        var steps = new List<HelperTailStep>();
        if (node is not JsonArray arr) return steps;
        foreach (var item in arr)
        {
            if (item is null) continue;
            if (ActivityJson.StrOrNull(item) is { Length: > 0 } plain)
            {
                steps.Add(new HelperTailStep(plain));
                continue;
            }
            var text = item.Text("text") ?? item.Text("label") ?? item.Text("tool");
            if (text is null)
            {
                var toolName = item.Text("tool_name");
                if (toolName is not null)
                    text = SubagentRules.FormatTool(toolName, item.Text("tool_preview") ?? "");
            }
            if (string.IsNullOrEmpty(text)) continue;
            var kind = (item.Text("kind") ?? "").ToLowerInvariant() switch
            {
                "tool" => SubagentStreamKind.Tool,
                "thinking" => SubagentStreamKind.Thinking,
                "summary" => SubagentStreamKind.Summary,
                _ => item.Text("tool_name") is not null ? SubagentStreamKind.Tool : SubagentStreamKind.Progress,
            };
            var at = ActivityJson.Num(item.Get("at")) ?? ActivityJson.Num(item.Get("timestamp"));
            var isError = ActivityJson.IsBool(item.Get("is_error"), true) || ActivityJson.IsBool(item.Get("error"), true);
            steps.Add(new HelperTailStep(text, kind, at, isError));
        }
        return steps;
    }

    private static List<HelperTailFile> ParseFiles(JsonNode? result)
    {
        var files = new List<HelperTailFile>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        void Add(string? path, bool written)
        {
            if (string.IsNullOrWhiteSpace(path)) return;
            var key = $"{(written ? 'W' : 'R')}:{path}";
            if (seen.Add(key)) files.Add(new HelperTailFile(path.Trim(), written));
        }

        foreach (var p in ActivityJson.Strings(result.Get("files_written"))) Add(p, true);
        foreach (var p in ActivityJson.Strings(result.Get("files_read"))) Add(p, false);

        if (result.Get("files") is JsonArray arr)
        {
            foreach (var item in arr)
            {
                if (item is null) continue;
                if (ActivityJson.StrOrNull(item) is { Length: > 0 } pathOnly)
                {
                    Add(pathOnly, false);
                    continue;
                }
                var path = item.Text("path") ?? item.Text("file");
                var written = ActivityJson.IsBool(item.Get("written"), true)
                    || string.Equals(item.Text("mode"), "write", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(item.Text("action"), "wrote", StringComparison.OrdinalIgnoreCase);
                Add(path, written);
            }
        }
        return files;
    }
}
