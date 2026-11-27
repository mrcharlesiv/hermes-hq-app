using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hermes.Core.Activity;

// Task-list rules (docs/spec/1x-activity.md §5.2), port of HermesKit/Activity/TodoRules.swift (V:lib/todos.ts,
// V:store/todos.ts). `TodoState` is one chat's live list, its retained ("Previous tasks") list and the revision watermark;
// the 4 s linger after a list finishes is a deadline the store's clock checks.

public static class TodoRules
{
    public const double FinishedLinger = 4;

    public static bool IsTodoTool(string? name) => name is "todo" or "todo_list";

    public static bool Active(IEnumerable<TodoItem> todos) =>
        todos.Any(t => t.Status is TodoStatus.Pending or TodoStatus.InProgress);

    // MARK: Parse

    private static TodoStatus? Status(JsonNode? value) => TodoStatusExtensions.Parse(ActivityJson.StrOrNull(value));

    /// `String(item.id ?? '')`: strings as they are, numbers in JavaScript's form.
    private static string Text(JsonNode? value)
    {
        if (value is not JsonValue jv) return "";
        return jv.GetValueKind() switch
        {
            JsonValueKind.String => jv.GetValue<string>(),
            JsonValueKind.Number => ActivityJson.Num(jv) is { } n ? ActivityJson.JsNumber(n) : "",
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => "",
        };
    }

    private static List<TodoItem> ParseArray(JsonArray values)
    {
        var output = new List<TodoItem>();
        foreach (var value in values)
        {
            if (value is not JsonObject item || Status(item["status"]) is not { } status) continue;
            var id = Text(item["id"]).Trim();
            var content = Text(item["content"]).Trim();
            var parent = Text(item["parent"]).Trim();
            if (id.Length == 0 || content.Length == 0) continue;
            output.Add(new TodoItem(id, content, status, parent.Length == 0 || parent == id ? null : parent));
        }
        return output;
    }

    private static List<TodoPatch> ParsePatchArray(JsonArray values)
    {
        var output = new List<TodoPatch>();
        foreach (var value in values)
        {
            if (value is not JsonObject item || Status(item["status"]) is not { } status) continue;
            var id = Text(item["id"]).Trim();
            if (id.Length == 0) continue;
            var content = Text(item["content"]).Trim();
            output.Add(new TodoPatch(id, content.Length == 0 ? null : content, status));
        }
        return output;
    }

    /// An array, a JSON string of one, or `{todos: …}` (≤ 2 levels deep); null when it is none of them.
    public static List<TodoItem>? ParseTodos(JsonNode? value, int depth = 0)
    {
        if (depth > 2 || value is null) return null;
        switch (value)
        {
            case JsonArray a: return ParseArray(a);
            case JsonValue v when ActivityJson.StrOrNull(v) is { } s:
                if (s.Trim().Length == 0 || J.Parse(s) is not { } parsed) return null;
                return ParseTodos(parsed, depth + 1);
            case JsonObject o:
                return o.TryGetPropertyValue("todos", out var todos) && todos is not null ? ParseTodos(todos, depth + 1) : null;
            default: return null;
        }
    }

    public static List<TodoPatch>? ParsePatch(JsonNode? value, int depth = 0)
    {
        if (depth > 2 || value is null) return null;
        switch (value)
        {
            case JsonArray a: return ParsePatchArray(a);
            case JsonValue v when ActivityJson.StrOrNull(v) is { } s:
                if (s.Trim().Length == 0 || J.Parse(s) is not { } parsed) return null;
                return ParsePatch(parsed, depth + 1);
            case JsonObject o:
                return o.TryGetPropertyValue("todos", out var todos) && todos is not null ? ParsePatch(todos, depth + 1) : null;
            default: return null;
        }
    }

    /// `parseTodoRevision`: a safe non-negative integer `revision`, looked for in the value and its `result`.
    public static int? ParseRevision(JsonNode? value, int depth = 0)
    {
        if (depth > 2 || value is null) return null;
        switch (value)
        {
            case JsonValue v when ActivityJson.StrOrNull(v) is { } s:
                if (s.Trim().Length == 0 || J.Parse(s) is not { } parsed) return null;
                return ParseRevision(parsed, depth + 1);
            case JsonObject o:
                if (ActivityJson.Int(o["revision"]) is { } r && r >= 0) return r;
                return o.TryGetPropertyValue("result", out var result) && result is not null ? ParseRevision(result, depth + 1) : null;
            default: return null;
        }
    }

    // MARK: Order and merge

    /// Parents before children, `(item, depth)`; dangling parents go to the top level and cycle members are appended
    /// flat (`todoTree`).
    public static List<(TodoItem Item, int Depth)> Tree(IReadOnlyList<TodoItem> todos)
    {
        var ids = todos.Select(t => t.Id).ToHashSet(StringComparer.Ordinal);
        var kids = new Dictionary<string, List<TodoItem>>(StringComparer.Ordinal);
        var roots = new List<TodoItem>();
        foreach (var t in todos)
        {
            if (t.Parent is { } parent && ids.Contains(parent) && parent != t.Id)
            {
                if (!kids.TryGetValue(parent, out var list)) kids[parent] = list = [];
                list.Add(t);
            }
            else roots.Add(t);
        }
        var output = new List<(TodoItem, int)>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        void Walk(TodoItem item, int depth)
        {
            if (!seen.Add(item.Id)) return;
            output.Add((item, depth));
            foreach (var kid in kids.GetValueOrDefault(item.Id) ?? []) Walk(kid, depth + 1);
        }
        foreach (var root in roots) Walk(root, 0);
        foreach (var t in todos)
            if (seen.Add(t.Id)) output.Add((t, 0));
        return output;
    }

    /// `TodoStore.write(merge=True)`: update by id, append unknown ids.
    public static List<TodoItem> Merge(IReadOnlyList<TodoItem> current, IReadOnlyList<TodoPatch> patch)
    {
        var next = current.ToList();
        var index = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var i = 0; i < next.Count; i++) index[next[i].Id] = i;
        foreach (var p in patch)
        {
            if (index.TryGetValue(p.Id, out var i))
            {
                var item = next[i];
                if (!string.IsNullOrEmpty(p.Content)) item = item with { Content = p.Content };
                next[i] = item with { Status = p.Status };
            }
            else
            {
                var content = p.Content?.Trim() ?? "";
                next.Add(new TodoItem(p.Id, content.Length == 0 ? "(no description)" : content, p.Status));
                index[p.Id] = next.Count - 1;
            }
        }
        return next;
    }

    /// `nextTodosFromToolEvent`: a full list from `todos` / `result`, else `args` (a merge patch when `merge: true`).
    public static List<TodoItem>? NextTodos(IReadOnlyList<TodoItem> current, JsonNode? payload)
    {
        if ((ParseTodos(payload.Get("todos")) ?? ParseTodos(payload.Get("result"))) is { } full) return full;
        var args = ActivityJson.Has(payload, "args") ? payload.Get("args") : payload.Get("arguments");
        if (args is JsonObject o && ActivityJson.IsBool(o["merge"], true))
        {
            if (ParsePatch(args) is not { Count: > 0 } patch) return null;
            return Merge(current, patch);
        }
        return ParseTodos(args);
    }

    // MARK: Words

    /// "Tasks 1/3": every item counts, cancelled included.
    public static string ChipWords(IReadOnlyCollection<TodoItem> todos, bool previous)
    {
        var done = todos.Count(t => t.Status == TodoStatus.Completed);
        return $"{(previous ? "Previous tasks" : "Tasks")} {done}/{todos.Count}";
    }
}

/// One chat's task lists (V:store/todos.ts for one session).
public sealed class TodoState
{
    private sealed record S(ValueList<TodoItem>? Live, ValueList<TodoItem> Retained, int? Revision, double? DropAt);

    private S _s = new(null, ValueList<TodoItem>.Empty, null, null);

    /// null = no live list.
    public ValueList<TodoItem>? Live => _s.Live;
    public ValueList<TodoItem> Retained => _s.Retained;
    public int? Revision => _s.Revision;
    /// When a finished live list goes away (seconds since 1970).
    public double? DropAt => _s.DropAt;
    public bool IsEmpty => _s == new S(null, ValueList<TodoItem>.Empty, null, null);

    /// `acceptRevision`: an older versioned snapshot is ignored; an unversioned one applies and leaves the watermark.
    private bool Accept(int? revision)
    {
        if (revision is null) return true;
        if (_s.Revision is { } current && revision < current) return false;
        _s = _s with { Revision = revision };
        return true;
    }

    /// `setSessionTodos`.
    public bool Set(IReadOnlyList<TodoItem> todos, int? revision, double now)
    {
        var before = _s;
        if (!Accept(revision)) return false;
        var list = new ValueList<TodoItem>(todos);
        if (revision is not null) _s = _s with { Retained = list };
        _s = _s with { Live = list, DropAt = TodoRules.Active(todos) ? null : now + TodoRules.FinishedLinger };
        return _s != before;
    }

    /// The linger is over: the finished live list goes (the retained one stays).
    public bool Expire(double now)
    {
        if (_s.DropAt is not { } dropAt || now < dropAt) return false;
        _s = _s with { Live = null, DropAt = null };
        return true;
    }

    /// Turn end: a still-active live list is dropped (`clearActiveSessionTodos`).
    public bool DropActive()
    {
        if (_s.Live is not { } live || !TodoRules.Active(live)) return false;
        _s = _s with { Live = null, DropAt = null };
        return true;
    }

    /// Stop: everything goes, the watermark too.
    public bool Clear()
    {
        var before = _s;
        _s = new(null, ValueList<TodoItem>.Empty, null, null);
        return _s != before;
    }

    /// `restoreSessionTodosFromSnapshot` (`session.resume` / `activate` `todo_state`): an empty list at revision 0 or
    /// none is not a snapshot; a running chat applies it; an idle one applies only a finished list already showing,
    /// otherwise it keeps the retained copy and drops the live one (an idle chat's finished list goes straight to
    /// Previous tasks, folded, so opening it doesn't bounce).
    public bool Restore(JsonNode? snapshot, bool running, double now)
    {
        if (TodoRules.ParseTodos(snapshot) is not { } todos) return false;
        var revision = TodoRules.ParseRevision(snapshot);
        if (todos.Count == 0 && (revision is null || revision == 0)) return false;
        if (running || (!TodoRules.Active(todos) && _s.Live is not null)) return Set(todos, revision, now);
        var before = _s;
        if (!Accept(revision)) return false;
        if (revision is not null) _s = _s with { Retained = new(todos) };
        _s = _s with { Live = null, DropAt = null };
        return _s != before;
    }
}
