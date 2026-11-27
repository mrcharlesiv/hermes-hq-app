using System.Collections;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hermes.Core.Activity;

// Value types of the activity stream (docs/spec/1x-activity.md §3): a chat's subagents, its task lists and its goal.
// Port of HermesKit/Activity/ActivityModels.swift. Pure data: the activity is live state and never reaches the disk.

/// An immutable list with value equality, so records holding lists compare like the Swift structs do.
[CollectionBuilder(typeof(ValueList), nameof(ValueList.Create))]
public sealed class ValueList<T> : IReadOnlyList<T>, IEquatable<ValueList<T>>
{
    public static readonly ValueList<T> Empty = new([]);
    private readonly T[] _items;

    public ValueList(IEnumerable<T> items) => _items = items.ToArray();

    public T this[int index] => _items[index];
    public int Count => _items.Length;
    public IEnumerator<T> GetEnumerator() => ((IEnumerable<T>)_items).GetEnumerator();
    IEnumerator IEnumerable.GetEnumerator() => _items.GetEnumerator();

    public bool Equals(ValueList<T>? other) =>
        other is not null && (ReferenceEquals(this, other) || _items.AsSpan().SequenceEqual(other._items, EqualityComparer<T>.Default));
    public override bool Equals(object? obj) => Equals(obj as ValueList<T>);
    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (var item in _items) h.Add(item);
        return h.ToHashCode();
    }
    public static bool operator ==(ValueList<T>? a, ValueList<T>? b) => a is null ? b is null : a.Equals(b);
    public static bool operator !=(ValueList<T>? a, ValueList<T>? b) => !(a == b);
    public override string ToString() => "[" + string.Join(", ", _items) + "]";
}

public static class ValueList
{
    public static ValueList<T> Create<T>(ReadOnlySpan<T> items) => new(items.ToArray());
    public static ValueList<T> ToValueList<T>(this IEnumerable<T> items) => new(items);
}

// MARK: - Subagents (§4)

public enum SubagentStatus
{
    Completed, Failed, Interrupted, Queued, Running,
    /// Transcript-only: dispatched in the background, with no observed outcome yet.
    Dispatched,
}

public static class SubagentStatusExtensions
{
    public static bool IsTerminal(this SubagentStatus s) =>
        s is SubagentStatus.Completed or SubagentStatus.Failed or SubagentStatus.Interrupted;
    public static bool IsLive(this SubagentStatus s) => s is SubagentStatus.Running or SubagentStatus.Queued;

    /// The wire word ("completed", "running"…).
    public static string RawValue(this SubagentStatus s) => s switch
    {
        SubagentStatus.Completed => "completed",
        SubagentStatus.Failed => "failed",
        SubagentStatus.Interrupted => "interrupted",
        SubagentStatus.Queued => "queued",
        SubagentStatus.Running => "running",
        _ => "dispatched",
    };
}

public enum SubagentStreamKind { Progress, Summary, Thinking, Tool }

/// One line of a child's activity. `At` is seconds since 1970.
public sealed record SubagentStreamEntry(double At, bool IsError, SubagentStreamKind Kind, string Text);

public sealed record SubagentProgress
{
    public required string Id { get; init; }
    public string? ParentId { get; init; }
    public required string Goal { get; init; }
    /// The child's own stored session id.
    public string? SessionId { get; init; }
    public string? DelegationId { get; init; }
    public string? Model { get; init; }
    public required SubagentStatus Status { get; init; }
    public int TaskCount { get; init; } = 1;
    public int TaskIndex { get; init; }
    /// Seconds since 1970 (a roster's `started_at` wins over the first event).
    public double StartedAt { get; init; }
    public double UpdatedAt { get; init; }
    public double? DurationSeconds { get; init; }
    public double? InputTokens { get; init; }
    public double? OutputTokens { get; init; }
    public double? ToolCount { get; init; }
    public ValueList<string> FilesRead { get; init; } = ValueList<string>.Empty;
    public ValueList<string> FilesWritten { get; init; } = ValueList<string>.Empty;
    /// Newest last, at most 24 (`SubagentRules.MaxStream`).
    public ValueList<SubagentStreamEntry> Stream { get; init; } = ValueList<SubagentStreamEntry>.Empty;
    public string? Summary { get; init; }
    /// The tool running now; cleared on a terminal status.
    public string? CurrentTool { get; init; }

    public bool IsLive => Status.IsLive();
    /// A row the app made from a `delegate_task` call (no gateway id behind it, §4.6).
    public bool IsDelegateStandIn => Id.StartsWith("delegate-tool:", StringComparison.Ordinal);
}

/// `subagent.tail` answer for one child (§2.2).
public sealed record SubagentTail(bool Available, string Text, bool Truncated);

// MARK: - Tasks (§5)

public enum TodoStatus { Pending, InProgress, Completed, Cancelled }

public static class TodoStatusExtensions
{
    public static string RawValue(this TodoStatus s) => s switch
    {
        TodoStatus.Pending => "pending",
        TodoStatus.InProgress => "in_progress",
        TodoStatus.Completed => "completed",
        _ => "cancelled",
    };

    public static TodoStatus? Parse(string? raw) => raw switch
    {
        "pending" => TodoStatus.Pending,
        "in_progress" => TodoStatus.InProgress,
        "completed" => TodoStatus.Completed,
        "cancelled" => TodoStatus.Cancelled,
        _ => null,
    };
}

public sealed record TodoItem(string Id, string Content, TodoStatus Status, string? Parent = null);

/// A `merge: true` write's item: content optional so a status-only patch applies to an existing row.
public sealed record TodoPatch(string Id, string? Content, TodoStatus Status);

// MARK: - Goal (§6, `session.control`)

public enum GoalStatus { Active, Paused, Done }
public enum GoalVerdict { Blocked, Continue, Done, Skipped, Wait }

public sealed record GoalContract(string Outcome = "", string Verification = "", string Constraints = "",
    string Boundaries = "", string StopWhen = "")
{
    public bool IsEmpty => Outcome.Length == 0 && Verification.Length == 0 && Constraints.Length == 0
        && Boundaries.Length == 0 && StopWhen.Length == 0;
}

public sealed record GoalGate(string Command, int TimeoutSeconds, int MaxRetries, int Attempts, int? LastExitCode);

public abstract record WaitBarrier(string Reason);
public sealed record WaitUntil(double At, string Reason) : WaitBarrier(Reason);
public sealed record WaitSession(string Target, string Reason) : WaitBarrier(Reason);
public sealed record WaitPid(int Target, string Reason) : WaitBarrier(Reason);

public sealed record GoalSnapshot
{
    public required string Title { get; init; }
    public required GoalStatus Status { get; init; }
    public int TurnsUsed { get; init; }
    public int MaxTurns { get; init; }
    public GoalContract Contract { get; init; } = new();
    public ValueList<string> Subgoals { get; init; } = ValueList<string>.Empty;
    public ValueList<GoalGate> Gates { get; init; } = ValueList<GoalGate>.Empty;
    public double? CreatedAt { get; init; }
    public double? UpdatedAt { get; init; }
    public string? PausedReason { get; init; }
    public GoalVerdict? LastVerdict { get; init; }
    public string? LastReason { get; init; }
    public WaitBarrier? WaitBarrier { get; init; }
}

public sealed record ControlSnapshot(GoalSnapshot? Goal, JsonNode? Loop, JsonNode? Heartbeat, string Revision, double UpdatedAt)
{
    // Loop and heartbeat are kept raw (out of scope, §14 item 2): compared by their JSON.
    public bool Equals(ControlSnapshot? other) =>
        other is not null && Goal == other.Goal && Revision == other.Revision && UpdatedAt.Equals(other.UpdatedAt)
        && JsonNode.DeepEquals(Loop, other.Loop) && JsonNode.DeepEquals(Heartbeat, other.Heartbeat);
    public override int GetHashCode() => HashCode.Combine(Goal, Revision, UpdatedAt);
}

public enum ControlCapability { Unknown, Supported, Unsupported }

/// One chat's goal state.
public sealed record ControlEntry(ControlCapability Capability = ControlCapability.Unknown, ControlSnapshot? Snapshot = null,
    /// The action running now (every goal action is disabled meanwhile).
    string? PendingAction = null,
    /// "Action failed: …" (≤ 240 characters), dismissed with its ✕.
    string? ActionError = null);

/// `session.control`'s `dispatch` envelope: every key present, any may be null (§2.2).
public sealed record ControlDispatch(string? Type, string? Output, string? Notice, string? Message, string? Display);

public enum SteerOutcome { Queued, Rejected }

// MARK: - One chat's activity

/// Everything the activity stream knows about one chat, as a value snapshot (§3.2).
public sealed record ChatActivity
{
    public static readonly ChatActivity None = new();

    /// The binding behind this snapshot.
    public string? RuntimeId { get; init; }
    /// All rows, terminal ones included, until the next `message.start` prunes them.
    public ValueList<SubagentProgress> Subagents { get; init; } = ValueList<SubagentProgress>.Empty;
    /// null = no live list (the Tasks chip is absent).
    public ValueList<TodoItem>? LiveTodos { get; init; }
    /// "Previous tasks": the last authoritative snapshot.
    public ValueList<TodoItem> RetainedTodos { get; init; } = ValueList<TodoItem>.Empty;
    public ControlEntry Control { get; init; } = new();
    /// A native `subagent.*` event arrived this turn (the `delegate_task` stand-ins stop, §4.6).
    public bool NativeSubagentEvents { get; init; }
    /// `subagent.tail` answers by subagent id (only while a child's detail is open).
    public IReadOnlyDictionary<string, SubagentTail> Tails { get; init; } = new Dictionary<string, SubagentTail>();
    /// Failed results stay available across turns until the person opens and leaves the result.
    public ValueList<SubagentProgress> UnreadHelperFailures { get; init; } = ValueList<SubagentProgress>.Empty;

    public IReadOnlyList<SubagentProgress> LiveSubagents => Subagents.Where(s => s.IsLive).ToList();
    public bool HasLiveSubagents => Subagents.Any(s => s.IsLive);
    public GoalSnapshot? Goal => Control.Snapshot?.Goal;
    /// The live list, else nothing (the brief's shorthand; `RetainedTodos` is the Previous tasks list).
    public IReadOnlyList<TodoItem> Todos => LiveTodos ?? ValueList<TodoItem>.Empty;

    /// Nothing for the shelf to show.
    public bool IsEmpty => Subagents.Count == 0 && LiveTodos is null && RetainedTodos.Count == 0 && Goal is null
        && UnreadHelperFailures.Count == 0;
}

// MARK: - Strict JSON readers (the web's `str` / `num` helpers: no coercion)

public static class ActivityJson
{
    /// A string value, else "".
    public static string Str(JsonNode? value) =>
        value is JsonValue jv && jv.GetValueKind() == JsonValueKind.String ? jv.GetValue<string>() : "";

    /// A string value, else null.
    public static string? StrOrNull(JsonNode? value) =>
        value is JsonValue jv && jv.GetValueKind() == JsonValueKind.String ? jv.GetValue<string>() : null;

    /// A finite number (never a numeric string).
    public static double? Num(JsonNode? value)
    {
        if (value is not JsonValue jv || jv.GetValueKind() != JsonValueKind.Number) return null;
        return double.TryParse(jv.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) && double.IsFinite(d)
            ? d : null;
    }

    /// An integer number (JSON `Number.isInteger`).
    public static int? Int(JsonNode? value) =>
        Num(value) is { } n && Round(n) == n && Math.Abs(n) < 9.007e15 && n is >= int.MinValue and <= int.MaxValue ? (int)n : null;

    public static bool IsBool(JsonNode? value, bool expected) =>
        value is JsonValue jv && jv.GetValueKind() == (expected ? JsonValueKind.True : JsonValueKind.False);

    public static List<string> Strings(JsonNode? value) =>
        value is JsonArray a ? a.Select(StrOrNull).OfType<string>().ToList() : [];

    /// An object, or a JSON string holding one (tool args and results arrive both ways). Never null.
    public static JsonObject Object(JsonNode? value) => value switch
    {
        JsonObject o => o,
        JsonValue v when StrOrNull(v) is { } s && J.Parse(s) is JsonObject parsed => parsed,
        _ => new JsonObject(),
    };

    /// JavaScript truthiness (`ChatJSON.isTruthy`).
    public static bool IsTruthy(JsonNode? value) => value switch
    {
        null => false,
        JsonValue jv => jv.GetValueKind() switch
        {
            JsonValueKind.True => true,
            JsonValueKind.Number => Num(jv) is { } n && n != 0,
            JsonValueKind.String => Str(jv).Length > 0,
            _ => false,
        },
        _ => true,
    };

    /// The key is in the object (a JSON null counts), as Swift's `dict[key] != nil`.
    public static bool Has(JsonNode? node, string key) => node is JsonObject o && o.ContainsKey(key);

    /// JavaScript's number-to-string ("Timed out after 9s", "612.3s"): integers without a decimal point, others in
    /// their shortest form.
    public static string JsNumber(double n)
    {
        if (Round(n) == n && Math.Abs(n) < 1e15) return ((long)n).ToString(CultureInfo.InvariantCulture);
        return n.ToString("R", CultureInfo.InvariantCulture);
    }

    /// Swift's `rounded()`: half away from zero.
    public static double Round(double x) => Math.Round(x, MidpointRounding.AwayFromZero);

    /// Characters as Swift counts them (grapheme clusters).
    public static int Length(string s) => new StringInfo(s).LengthInTextElements;

    public static string Prefix(string s, int count)
    {
        var info = new StringInfo(s);
        return count >= info.LengthInTextElements ? s : info.SubstringByTextElements(0, count);
    }
}
