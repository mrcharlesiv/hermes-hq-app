using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hermes.Core.Kanban;

// Wire shapes of the Kanban plugin (HermesKit/Pages/PagesWire.swift "Kanban (§4.1)"; docs/spec/1x-pages.md §4.1).
// Read leniently: every documented key optional, unknown keys ignored.

public sealed record KanbanDiagnosticAction(string Kind, string Label, string? Command);

public sealed record KanbanDiagnostic(string Kind, string Severity, string Title, string Detail, int Count, double? LastSeenAt,
    IReadOnlyList<KanbanDiagnosticAction> Actions)
{
    public static KanbanDiagnostic? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var actions = new List<KanbanDiagnosticAction>();
        foreach (var a in n.Arr("actions") ?? [])
        {
            if (a.Str("kind") is not { } kind) continue;
            actions.Add(new KanbanDiagnosticAction(kind, a.Str("label") ?? kind, a.Obj("payload").Str("command")));
        }
        return new KanbanDiagnostic(n.Str("kind") ?? "", n.Str("severity") ?? "warning", n.Str("title") ?? "",
            n.Str("detail") ?? "", (int)(n.Int("count") ?? 1), KanbanRest.Seconds(n, "last_seen_at"), actions);
    }
}

/// One card. `EditToken` is set by an optimistic edit here (never by the gateway): R21's "still exactly what this write left".
public sealed record KanbanTask(string Id, string Title, string Status)
{
    public string? Assignee { get; init; }
    public int? Priority { get; init; }
    public double? CreatedAt { get; init; }
    public double? CompletedAt { get; init; }
    public double? StartedAt { get; init; }
    public double? CurrentRunStartedAt { get; init; }
    public string? BlockKind { get; init; }
    public int? CommentCount { get; init; }
    public string? Body { get; init; }
    public string? LatestSummary { get; init; }
    public string? Result { get; init; }
    public string? CreatedBy { get; init; }
    public string? WorkspacePath { get; init; }
    public string? WorkspaceKind { get; init; }
    public string? ModelOverride { get; init; }
    public string? ReasoningEffort { get; init; }
    public string? LastFailureError { get; init; }
    public int? ConsecutiveFailures { get; init; }
    public IReadOnlyList<KanbanDiagnostic>? Diagnostics { get; init; }
    public int EditToken { get; init; }

    public static KanbanTask? From(JsonNode? n)
    {
        if (KanbanRest.Id(n, "id") is not { } id) return null;
        return new KanbanTask(id, n.Str("title") ?? "", n.Str("status") ?? "todo")
        {
            Assignee = n.Str("assignee") is { Length: > 0 } a ? a : null,
            Priority = n.Int("priority") is { } p ? (int)p : null,
            CreatedAt = KanbanRest.Seconds(n, "created_at"),
            CompletedAt = KanbanRest.Seconds(n, "completed_at"),
            StartedAt = KanbanRest.Seconds(n, "started_at"),
            CurrentRunStartedAt = KanbanRest.Seconds(n, "current_run_started_at"),
            BlockKind = n.Str("block_kind"),
            CommentCount = n.Int("comment_count") is { } c ? (int)c : null,
            Body = n.Str("body"),
            LatestSummary = n.Str("latest_summary"),
            Result = n.Str("result"),
            CreatedBy = n.Str("created_by"),
            WorkspacePath = n.Str("workspace_path"),
            WorkspaceKind = n.Str("workspace_kind"),
            ModelOverride = n.Str("model_override"),
            ReasoningEffort = n.Str("reasoning_effort"),
            LastFailureError = n.Str("last_failure_error"),
            ConsecutiveFailures = n.Int("consecutive_failures") is { } f ? (int)f : null,
            Diagnostics = n.Arr("diagnostics") is { } d ? [.. d.Select(KanbanDiagnostic.From).OfType<KanbanDiagnostic>()] : null,
        };
    }

    /// Value equality that looks into the diagnostics list (a record compares lists by reference).
    public bool Same(KanbanTask? other) => other != null && this with { Diagnostics = null } == other with { Diagnostics = null }
        && (Diagnostics?.Count ?? -1) == (other.Diagnostics?.Count ?? -1);
}

public sealed record KanbanColumn(string Name, IReadOnlyList<KanbanTask> Tasks);

public sealed record KanbanBoard(IReadOnlyList<KanbanColumn> Columns)
{
    public IReadOnlyList<string> Assignees { get; init; } = [];
    public long? LatestEventId { get; init; }

    public static KanbanBoard From(JsonNode? n)
    {
        var columns = new List<KanbanColumn>();
        foreach (var c in n.Arr("columns") ?? [])
        {
            if (c.Str("name") is not { } name) continue;
            columns.Add(new KanbanColumn(name, [.. (c.Arr("tasks") ?? []).Select(KanbanTask.From).OfType<KanbanTask>()]));
        }
        return new KanbanBoard(columns)
        {
            Assignees = [.. (n.Arr("assignees") ?? []).Select(J.AsString).OfType<string>()],
            LatestEventId = n.Int("latest_event_id"),
        };
    }

    public IEnumerable<KanbanTask> AllTasks => Columns.SelectMany(c => c.Tasks);
    public KanbanTask? Task(string id) => AllTasks.FirstOrDefault(t => t.Id == id);

    /// Where each task stands, in order: the board as a test or a cache compares it.
    public string Signature => string.Join("|", Columns.Select(c => c.Name + ":" + string.Join(",", c.Tasks.Select(t => t.Id + "/" + t.Status + "/" + t.EditToken))));
}

public sealed record KanbanBoardMeta(string Slug, string? Name, int? Total, bool IsCurrent);

public sealed record KanbanBoards(IReadOnlyList<KanbanBoardMeta> Boards, string Current)
{
    public static KanbanBoards From(JsonNode? n)
    {
        var boards = new List<KanbanBoardMeta>();
        foreach (var b in n.Arr("boards") ?? [])
        {
            if (b.Str("slug") is not { } slug) continue;
            boards.Add(new KanbanBoardMeta(slug, b.Str("name"), b.Int("total") is { } t ? (int)t : null, b.Bool("is_current") ?? false));
        }
        return new KanbanBoards(boards, n.Str("current") ?? boards.FirstOrDefault(b => b.IsCurrent)?.Slug ?? "");
    }

    /// Σ total (§4.2's "a board holds a task").
    public int TaskCount => Boards.Sum(b => b.Total ?? 0);
}

public sealed record KanbanProfile(string Name, bool IsDefault);
public sealed record KanbanComment(string Id, string Author, string Body, double? CreatedAt);
public sealed record KanbanEvent(string Id, string Kind, JsonNode? Payload, double? CreatedAt);
public sealed record KanbanTaskRun(string Id, string? Profile, string Status, string? Outcome, string? Summary, string? Error,
    double? StartedAt, double? EndedAt);
public sealed record KanbanAttachment(string Id, string Filename, long? Size);

public sealed record KanbanTaskDetail(KanbanTask Task, IReadOnlyList<KanbanComment> Comments, IReadOnlyList<KanbanEvent> Events,
    IReadOnlyList<KanbanTaskRun> Runs, IReadOnlyList<KanbanAttachment>? Attachments, IReadOnlyList<string> Parents,
    IReadOnlyList<string> Children, IReadOnlyDictionary<string, string> LinkTitles)
{
    /// null when the answer holds no task this app can read.
    public static KanbanTaskDetail? From(JsonNode? n)
    {
        if (KanbanTask.From(n.Get("task")) is not { } task) return null;
        var comments = (n.Arr("comments") ?? []).Select(c => KanbanRest.Id(c, "id") is { } id
            ? new KanbanComment(id, c.Str("author") ?? "", c.Str("body") ?? "", KanbanRest.Seconds(c, "created_at")) : null)
            .OfType<KanbanComment>().ToList();
        var events = (n.Arr("events") ?? []).Select(e => KanbanRest.Id(e, "id") is { } id
            ? new KanbanEvent(id, e.Str("kind") ?? "", e.Get("payload")?.DeepClone(), KanbanRest.Seconds(e, "created_at")) : null)
            .OfType<KanbanEvent>().ToList();
        var runs = (n.Arr("runs") ?? []).Select(r => KanbanRest.Id(r, "id") is { } id
            ? new KanbanTaskRun(id, r.Str("profile"), r.Str("status") ?? "", r.Str("outcome"), r.Str("summary"), r.Str("error"),
                KanbanRest.Seconds(r, "started_at"), KanbanRest.Seconds(r, "ended_at")) : null)
            .OfType<KanbanTaskRun>().ToList();
        // nil when the plugin's answer has no `attachments` key (an older plugin, §4.6.9).
        List<KanbanAttachment>? attachments = null;
        if (n.Get("attachments") is { } list && list.GetValueKind() != JsonValueKind.Null)
            attachments = [.. ((list as JsonArray) ?? []).Select(a => KanbanRest.Id(a, "id") is { } id
                ? new KanbanAttachment(id, a.Str("filename") ?? id, a.Int("size")) : null).OfType<KanbanAttachment>()];
        var titles = new Dictionary<string, string>();
        foreach (var linked in n.Arr("link_tasks") ?? [])
            if (KanbanRest.Id(linked, "id") is { } id && linked.Str("title") is { } title) titles[id] = title;
        return new KanbanTaskDetail(task, comments, events, runs, attachments,
            [.. (n.Obj("links").Arr("parents") ?? []).Select(J.AsString).OfType<string>()],
            [.. (n.Obj("links").Arr("children") ?? []).Select(J.AsString).OfType<string>()], titles);
    }
}

internal static class KanbanNumbers
{
    public static string Plain(double n) => n == Math.Round(n) && Math.Abs(n) < 9.007e15
        ? ((long)n).ToString(CultureInfo.InvariantCulture) : n.ToString(CultureInfo.InvariantCulture);
}
