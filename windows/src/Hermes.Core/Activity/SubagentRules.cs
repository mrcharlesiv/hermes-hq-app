using System.Globalization;
using System.Text.Json.Nodes;

namespace Hermes.Core.Activity;

// Subagent roster rules (docs/spec/1x-activity.md §4.2), a line-by-line port of HermesKit/Activity/SubagentRules.swift
// (itself V:store/subagents.ts and the delegate stand-ins of V:…/use-message-stream/utils.ts, §4.6). `SubagentRoster` is
// one chat's list plus the ids it retired; every mutation reports whether anything changed.

public sealed class SubagentRoster
{
    private ValueList<SubagentProgress> _items;
    private readonly HashSet<string> _retired = new(StringComparer.Ordinal);

    public SubagentRoster(IEnumerable<SubagentProgress>? items = null) =>
        _items = items is null ? ValueList<SubagentProgress>.Empty : new(items);

    public ValueList<SubagentProgress> Items => _items;
    /// Ids that were terminal in a list that has since been replaced: a late event or roster never brings them back.
    public IReadOnlySet<string> Retired => _retired;
    public int LiveCount => _items.Count(s => s.IsLive);

    /// Replace the list, retiring the terminal ids of the list it replaces (`setSessionSubagents`).
    private void Replace(IEnumerable<SubagentProgress> next)
    {
        foreach (var item in _items) if (item.Status.IsTerminal()) _retired.Add(item.Id);
        _items = new(next);
    }

    // MARK: Events

    /// `upsertSubagent`: creates only when `createIfMissing` (spawn_requested / start); terminal rows are frozen.
    public bool Upsert(JsonObject payload, bool createIfMissing, string? eventType, double now)
    {
        var id = SubagentRules.IdOf(payload);
        var index = IndexOf(_items, id);
        if (_retired.Contains(id) || (index < 0 && !createIfMissing)) return false;
        var prev = index >= 0 ? _items[index] : null;
        if (prev is not null && prev.Status.IsTerminal()) return false;
        var next = SubagentRules.ToProgress(payload, prev, eventType ?? "", now);
        var list = _items.ToList();
        if (index >= 0) list[index] = next; else list.Add(next);
        Replace(list);
        return true;
    }

    /// `pruneFinishedSessionSubagents` (message.start): keep running / queued rows.
    public bool PruneFinished() => Filter(s => s.IsLive);

    /// `pruneDelegateFallbackSubagents`: the first native event removes the `delegate-tool:` stand-ins.
    public bool PruneDelegateStandIns() => Filter(s => !s.IsDelegateStandIn);

    /// The turn ended (`message.complete`): a `delegate-tool:` stand-in still running missed its `tool.complete`.
    public bool PruneLiveDelegateStandIns() => Filter(s => !(s.IsDelegateStandIn && s.IsLive));

    /// `clearSessionSubagents` (Stop): everything goes, retirements included.
    public bool Clear()
    {
        var changed = _items.Count > 0 || _retired.Count > 0;
        _items = ValueList<SubagentProgress>.Empty;
        _retired.Clear();
        return changed;
    }

    /// Keep only the live rows whose gateway id is listed (`delegation.status` reconcile, §4.4). Stand-ins stay.
    public bool KeepLive(IReadOnlySet<string> listed) => Filter(s => !s.IsLive || s.IsDelegateStandIn || listed.Contains(s.Id));

    private bool Filter(Func<SubagentProgress, bool> keep)
    {
        var next = _items.Where(keep).ToList();
        if (next.Count == _items.Count) return false;
        Replace(next);
        return true;
    }

    private static int IndexOf(IReadOnlyList<SubagentProgress> list, string id)
    {
        for (var i = 0; i < list.Count; i++) if (list[i].Id == id) return i;
        return -1;
    }

    // MARK: Roster (`subagent.list`)

    /// `reconcileSubagentSnapshot`: keep terminal rows and listed ones; merge each listed child; failed delegations the
    /// list doesn't cover land as terminal failed rows.
    public bool Reconcile(IReadOnlyList<JsonObject> children, IReadOnlyList<JsonObject>? failedDelegations, double now)
    {
        var previous = _items;
        var ids = children.Select(c => ActivityJson.Str(c["subagent_id"])).Where(s => s.Length > 0).ToHashSet(StringComparer.Ordinal);
        var next = previous.Where(s => s.Status.IsTerminal() || ids.Contains(s.Id)).ToList();

        foreach (var payload in children)
        {
            var id = ActivityJson.Str(payload["subagent_id"]);
            if (id.Length == 0 || _retired.Contains(id)) continue;
            var index = IndexOf(next, id);
            var prev = index >= 0 ? next[index] : null;
            if (prev is not null && prev.Status.IsTerminal()) continue;
            var projected = SubagentRules.ToProgress(payload, prev, "", now);
            var started = ActivityJson.Num(payload["started_at"]) ?? 0;
            projected = projected with { StartedAt = started != 0 ? started : prev?.StartedAt ?? projected.StartedAt };
            projected = projected with { UpdatedAt = prev?.UpdatedAt ?? projected.StartedAt };
            // A roster names the last tool, not a call running now: seed cold activity only.
            var lastTool = ActivityJson.Str(payload["last_tool"]);
            if (projected.Stream.Count == 0 && lastTool.Length > 0)
                projected = projected with
                {
                    Stream = [new SubagentStreamEntry(projected.UpdatedAt, false, SubagentStreamKind.Tool, SubagentRules.FormatTool(lastTool))],
                };
            if (index >= 0) { if (next[index] != projected) next[index] = projected; }
            else next.Add(projected);
        }

        foreach (var payload in failedDelegations ?? [])
        {
            var id = SubagentRules.FailedDelegationId(payload);
            var delegationId = ActivityJson.Str(payload["delegation_id"]);
            var taskIndex = ActivityJson.Int(payload["task_index"]) ?? 0;
            if (delegationId.Length == 0 || _retired.Contains(id)
                || next.Any(s => s.Id == id || (s.DelegationId == delegationId && s.TaskIndex == taskIndex)))
                continue;
            var completed = ActivityJson.Num(payload["completed_at"]) ?? 0;
            var at = completed != 0 ? completed : now;
            var dispatched = ActivityJson.Num(payload["dispatched_at"]) ?? 0;
            var startedAt = dispatched != 0 ? dispatched : at;
            var merged = (JsonObject)payload.DeepClone();
            merged["subagent_id"] = id;
            merged["summary"] = ActivityJson.Str(payload["error"]);
            var row = SubagentRules.ToProgress(merged, null, "subagent.complete", now) with
            {
                DurationSeconds = Math.Max(0, ActivityJson.Round(at - startedAt)),
                Id = id,
                StartedAt = startedAt,
                UpdatedAt = at,
            };
            next.Add(row);
        }

        if (new ValueList<SubagentProgress>(next) == previous) return false;
        Replace(next);
        return true;
    }
}

public static class SubagentRules
{
    public const int MaxStream = 24;
    public const int PreviewMax = 220;
    public const int ToolPreviewMax = 96;

    /// `idOf`: the gateway's id, else `<parent or root>:<task index>:<goal>`.
    public static string IdOf(JsonNode? p)
    {
        var id = ActivityJson.Str(p.Get("subagent_id"));
        if (id.Length > 0) return id;
        var parent = ActivityJson.Str(p.Get("parent_id"));
        var index = ActivityJson.Num(p.Get("task_index")) is { } n ? ActivityJson.JsNumber(n) : "0";
        return $"{(parent.Length == 0 ? "root" : parent)}:{index}:{ActivityJson.Str(p.Get("goal"))}";
    }

    public static string FailedDelegationId(JsonNode? p)
    {
        var index = ActivityJson.Num(p.Get("task_index")) is { } n ? ActivityJson.JsNumber(n) : "0";
        return $"delegation:{ActivityJson.Str(p.Get("delegation_id"))}:{index}";
    }

    /// `asStatus`: timeout/error → failed, cancelled → interrupted; a completion with anything else fails closed.
    public static SubagentStatus Status(JsonNode? value, bool terminalEvent) => Status(ActivityJson.Str(value), terminalEvent);

    public static SubagentStatus Status(string s, bool terminalEvent) => s switch
    {
        "completed" => SubagentStatus.Completed,
        "failed" => SubagentStatus.Failed,
        "interrupted" => SubagentStatus.Interrupted,
        "timeout" or "error" => SubagentStatus.Failed,
        "cancelled" or "canceled" => SubagentStatus.Interrupted,
        _ when terminalEvent => SubagentStatus.Failed,
        "queued" => SubagentStatus.Queued,
        _ => SubagentStatus.Running,
    };

    /// Whitespace collapsed, at most `max` characters with "…".
    public static string Compact(string text, int max = PreviewMax)
    {
        var line = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (line.Length == 0) return "";
        return ActivityJson.Length(line) > max ? ActivityJson.Prefix(line, max - 1) + "…" : line;
    }

    /// `read_file` → "Read File"; with a preview: `Read File("CHANGELOG.md")`.
    public static string FormatTool(string name, string preview = "")
    {
        var words = name.Split('_', StringSplitOptions.RemoveEmptyEntries)
            .Select(w => char.IsSurrogate(w[0]) ? w : w[0].ToString().ToUpperInvariant() + w[1..]).ToList();
        var label = words.Count == 0 ? name : string.Join(' ', words);
        var snippet = Compact(preview, ToolPreviewMax);
        return snippet.Length == 0 ? label : $"{label}(\"{snippet}\")";
    }

    public static string TimeoutSummary(JsonNode? p)
    {
        if (ActivityJson.Str(p.Get("status")) != "timeout") return "";
        var seconds = ActivityJson.Num(p.Get("duration_seconds")) is { } n ? ActivityJson.JsNumber(n) : "?";
        return $"Timed out after {seconds}s";
    }

    public static List<SubagentStreamEntry> Stream(JsonNode? p, SubagentStatus status, string eventType, double at)
    {
        var output = new List<SubagentStreamEntry>();
        var tool = ActivityJson.Str(p.Get("tool_name"));
        var toolPreview = ActivityJson.Str(p.Get("tool_preview"));
        var preview = toolPreview.Length == 0 ? ActivityJson.Str(p.Get("text")) : toolPreview;
        var rawText = ActivityJson.Str(p.Get("text"));
        var text = Compact(rawText.Length == 0 ? preview : rawText);
        var isError = ActivityJson.IsTruthy(p.Get("error"));
        if (p.Get("output_tail") is JsonArray tail)
        {
            foreach (var item in tail)
            {
                if (item is not JsonObject entry) continue;
                var tailTool = ActivityJson.Str(entry["tool"]);
                var tailPreview = ActivityJson.Str(entry["preview"]);
                var line = tailTool.Length == 0 ? Compact(tailPreview) : FormatTool(tailTool, tailPreview);
                if (line.Length > 0)
                    output.Add(new(at, ActivityJson.IsBool(entry["is_error"], true),
                        tailTool.Length == 0 ? SubagentStreamKind.Progress : SubagentStreamKind.Tool, line));
            }
        }
        if (tool.Length > 0) output.Add(new(at, isError, SubagentStreamKind.Tool, FormatTool(tool, preview)));
        if (eventType == "subagent.progress" && text.Length > 0) output.Add(new(at, isError, SubagentStreamKind.Progress, text));
        if (eventType == "subagent.thinking" && text.Length > 0) output.Add(new(at, false, SubagentStreamKind.Thinking, text));
        var summarySource = new[] { ActivityJson.Str(p.Get("summary")), rawText, TimeoutSummary(p) }.FirstOrDefault(s => s.Length > 0) ?? "";
        var summary = Compact(summarySource);
        if (status.IsTerminal() && summary.Length > 0)
            output.Add(new(at, status == SubagentStatus.Failed, SubagentStreamKind.Summary, summary));
        return output;
    }

    /// A repeat of the last entry is not appended; at most `MaxStream` entries.
    public static ValueList<SubagentStreamEntry> Append(ValueList<SubagentStreamEntry> stream, SubagentStreamEntry entry)
    {
        if (stream.Count > 0 && stream[^1] is var last && last.Kind == entry.Kind && last.Text == entry.Text && last.IsError == entry.IsError)
            return stream;
        var all = stream.Append(entry).ToList();
        return new(all.Skip(Math.Max(0, all.Count - MaxStream)));
    }

    /// `toProgress`: one event (or roster entry) merged over the previous row.
    public static SubagentProgress ToProgress(JsonNode? p, SubagentProgress? prev, string eventType, double now)
    {
        var status = Status(p.Get("status"), eventType == "subagent.complete");
        var tool = ActivityJson.Str(p.Get("tool_name"));
        var stream = Stream(p, status, eventType, now).Aggregate(prev?.Stream ?? ValueList<SubagentStreamEntry>.Empty, Append);
        var filesRead = ActivityJson.Strings(p.Get("files_read"));
        var filesWritten = ActivityJson.Strings(p.Get("files_written"));
        static string? NonEmpty(string? s) => string.IsNullOrEmpty(s) ? null : s;
        var summary = NonEmpty(ActivityJson.Str(p.Get("summary"))) ?? NonEmpty(TimeoutSummary(p)) ?? prev?.Summary;
        return new SubagentProgress
        {
            Id = prev?.Id ?? IdOf(p),
            ParentId = NonEmpty(ActivityJson.Str(p.Get("parent_id"))) ?? prev?.ParentId,
            Goal = NonEmpty(ActivityJson.Str(p.Get("goal"))) ?? NonEmpty(prev?.Goal) ?? "Helper",
            SessionId = NonEmpty(ActivityJson.Str(p.Get("child_session_id"))) ?? prev?.SessionId,
            DelegationId = NonEmpty(ActivityJson.Str(p.Get("delegation_id"))) ?? prev?.DelegationId,
            Model = NonEmpty(ActivityJson.Str(p.Get("model"))) ?? prev?.Model,
            Status = status,
            TaskCount = ActivityJson.Num(p.Get("task_count")) is { } tc ? (int)tc : prev?.TaskCount ?? 1,
            TaskIndex = ActivityJson.Num(p.Get("task_index")) is { } ti ? (int)ti : prev?.TaskIndex ?? 0,
            StartedAt = prev?.StartedAt ?? now,
            UpdatedAt = now,
            DurationSeconds = ActivityJson.Num(p.Get("duration_seconds")) ?? prev?.DurationSeconds,
            InputTokens = ActivityJson.Num(p.Get("input_tokens")) ?? prev?.InputTokens,
            OutputTokens = ActivityJson.Num(p.Get("output_tokens")) ?? prev?.OutputTokens,
            ToolCount = ActivityJson.Num(p.Get("tool_count")) ?? prev?.ToolCount,
            FilesRead = filesRead.Count == 0 ? prev?.FilesRead ?? ValueList<string>.Empty : new(filesRead),
            FilesWritten = filesWritten.Count == 0 ? prev?.FilesWritten ?? ValueList<string>.Empty : new(filesWritten),
            Stream = stream,
            Summary = summary,
            CurrentTool = status.IsTerminal() ? null : NonEmpty(tool) ?? prev?.CurrentTool,
        };
    }

    // MARK: Delegate stand-ins (§4.6, `delegateTaskPayloads`)

    /// The rows a `delegate_task` tool event stands in for on gateways that send no `subagent.*` (one per task).
    public static List<JsonObject> DelegatePayloads(JsonNode? payload, bool complete, string sourceEventType)
    {
        if (ActivityJson.StrOrNull(payload.Get("name")) != "delegate_task") return [];
        var args = ActivityJson.Object(ActivityJson.Has(payload, "args") ? payload.Get("args") : payload.Get("input"));
        var result = ActivityJson.Object(payload.Get("result"));
        var rawTasks = args["tasks"] is JsonArray ta ? ta.ToList() : [];
        var rawResults = (result["results"] as JsonArray)?.Select(ActivityJson.Object).ToList() ?? [];
        // Indexed rows may arrive out of order. Only an unindexed row may stand in for its array position.
        var results = new Dictionary<int, JsonObject>();
        for (var position = 0; position < rawResults.Count; position++)
        {
            var row = rawResults[position];
            var explicitIndex = ActivityJson.Int(row["task_index"]);
            if (row.ContainsKey("task_index") && (explicitIndex is null || explicitIndex < 0)) continue;
            var index = explicitIndex ?? position;
            if (explicitIndex is not null || !results.ContainsKey(index)) results[index] = row;
        }
        List<JsonObject> tasks = rawTasks.Count == 0
            ? (args.Count > 0 || rawResults.Count == 0 ? [args] : [])
            : rawTasks.Select(ActivityJson.Object).ToList();
        var indices = Enumerable.Range(0, tasks.Count).Union(results.Keys).Distinct().Order().ToList();
        var taskCount = (indices.Count > 0 ? indices[^1] : 0) + 1;
        var resultStatus = ActivityJson.Str(result["status"]).ToLowerInvariant();
        var failed = ActivityJson.IsTruthy(payload.Get("error")) || resultStatus is "timeout" or "error" or "failed" or "failure";
        var toolId = new[] { "tool_id", "tool_call_id", "id" }.Select(k => ActivityJson.Str(payload.Get(k))).FirstOrDefault(s => s.Length > 0)
            ?? "delegate_task";
        var progress = new[] { "preview", "message", "context" }.Select(k => ActivityJson.Str(payload.Get(k))).FirstOrDefault(s => s.Length > 0) ?? "";
        var eventType = complete ? "subagent.complete" : sourceEventType == "tool.start" ? "subagent.start" : "subagent.progress";
        return indices.Select(index =>
        {
            var task = index < tasks.Count ? tasks[index] : new JsonObject();
            var row = results.TryGetValue(index, out var r) ? r : new JsonObject();
            var rowStatus = ActivityJson.Str(row["status"]).ToLowerInvariant();
            SubagentStatus resolved;
            if (!complete) resolved = SubagentStatus.Running;
            else if (failed || ActivityJson.IsTruthy(row["error"])) resolved = SubagentStatus.Failed;
            else if (rowStatus.Length == 0 || rowStatus == "ok") resolved = SubagentStatus.Completed;
            else resolved = Status(rowStatus, terminalEvent: true);
            var summary = new[] { row["summary"], result["summary"], payload.Get("summary"), payload.Get("message") }
                .Select(ActivityJson.Str).FirstOrDefault(s => s.Length > 0) ?? "";
            // Completion need not repeat args. An empty goal lets the roster retain the start event's title.
            var goal = new[] { task["goal"], row["goal"], args["goal"], payload.Get("context") }
                .Select(ActivityJson.Str).FirstOrDefault(s => s.Length > 0) ?? (complete ? "" : "Delegated task");
            var output = new JsonObject
            {
                ["depth"] = 0,
                ["goal"] = goal,
                ["status"] = resolved.RawValue(),
                ["subagent_id"] = $"delegate-tool:{toolId}:{index}",
                ["task_count"] = (double)taskCount,
                ["task_index"] = (double)index,
            };
            if ((ActivityJson.Num(row["duration_seconds"]) ?? ActivityJson.Num(payload.Get("duration_s"))) is { } d) output["duration_seconds"] = d;
            if (summary.Length > 0) output["summary"] = summary;
            if (eventType == "subagent.progress") output["text"] = progress.Length == 0 ? goal : progress;
            if (eventType == "subagent.start")
            {
                output["tool_name"] = "delegate_task";
                if (progress.Length > 0) output["tool_preview"] = progress;
            }
            if (complete && summary.Length > 0)
                output["output_tail"] = new JsonArray(new JsonObject
                {
                    ["is_error"] = resolved == SubagentStatus.Failed, ["preview"] = summary, ["tool"] = "delegate_task",
                });
            return output;
        }).ToList();
    }

    // MARK: Words

    /// "Ns" under a minute, else "m:ss", and "h:mm:ss" from an hour (never "75:00").
    public static string FormatElapsed(int seconds)
    {
        var s = Math.Max(0, seconds);
        if (s < 60) return $"{s}s";
        if (s < 3600) return string.Create(CultureInfo.InvariantCulture, $"{s / 60}:{s % 60:00}");
        return string.Create(CultureInfo.InvariantCulture, $"{s / 3600}:{s / 60 % 60:00}:{s % 60:00}");
    }

    /// The tool cards' duration words (`ToolCards.formatDurationSeconds`): "350ms", "4.2s", "42s", "2m 5s", "1h 3m".
    public static string FormatDurationSeconds(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0) return "";
        if (seconds < 1) return $"{Math.Max(1, (int)ActivityJson.Round(seconds * 1000))}ms";
        if (seconds < 60)
            return seconds >= 10 ? $"{(int)ActivityJson.Round(seconds)}s" : seconds.ToString("F1", CultureInfo.InvariantCulture) + "s";
        var whole = (int)ActivityJson.Round(seconds);
        int minutes = whole / 60, rem = whole % 60;
        if (minutes < 60) return rem > 0 ? $"{minutes}m {rem}s" : $"{minutes}m";
        int hours = minutes / 60, remMinutes = minutes % 60;
        return remMinutes > 0 ? $"{hours}h {remMinutes}m" : $"{hours}h";
    }

    /// The detail's stats duration (`fmtDuration`): "" for none, else the tool cards' words.
    public static string FormatDuration(double? seconds) =>
        seconds is { } s && s > 0 ? FormatDurationSeconds(s) : "";

    /// `fmtAge`: "now" under 2 s, "Ns ago", "Nm ago", then unbounded hours "Nh ago".
    public static string FormatAge(double seconds)
    {
        var s = Math.Max(0, (int)ActivityJson.Round(seconds));
        if (s < 2) return "now";
        if (s < 60) return $"{s}s ago";
        var m = s / 60;
        return m < 60 ? $"{m}m ago" : $"{m / 60}h ago";
    }

    /// `compactNumber`: 999 → "999", 1230 → "1.2k", 1_500_000 → "1.5M".
    public static string CompactNumber(double value)
    {
        if (!double.IsFinite(value) || value <= 0) return "0";
        static string Scaled(double v, string suffix)
        {
            var text = v.ToString("F1", CultureInfo.InvariantCulture);
            if (text.EndsWith(".0", StringComparison.Ordinal)) text = text[..^2];
            return text + suffix;
        }
        if (value >= 999_950) return Scaled(value / 1_000_000, "M");
        if (value >= 999.5) return Scaled(value / 1_000, "k");
        return ((long)ActivityJson.Round(value)).ToString(CultureInfo.InvariantCulture);
    }

    /// The opened child's stats line: model · duration · N tools · N tok · updated &lt;age&gt;.
    public static string StatsLine(SubagentProgress s, double now)
    {
        var elapsed = Math.Max(0, Math.Floor(now - s.StartedAt));
        var duration = s.DurationSeconds is { } d ? Math.Max(0, ActivityJson.Round(d)) : elapsed;
        var tokens = (s.InputTokens ?? 0) + (s.OutputTokens ?? 0);
        string[] parts =
        [
            s.Model ?? "", FormatDuration(duration),
            (s.ToolCount ?? 0) > 0 ? $"{ActivityJson.JsNumber(s.ToolCount ?? 0)} tools" : "",
            tokens > 0 ? $"{CompactNumber(tokens)} tok" : "",
            $"updated {FormatAge(now - s.UpdatedAt)}",
        ];
        return string.Join(" · ", parts.Where(p => p.Length > 0));
    }

    /// "1 helper" / "2 helpers": the chip's word ("subagent" is a developer's word).
    public static string ChipWords(int liveCount) => liveCount == 1 ? "1 helper" : $"{liveCount} helpers";
}
