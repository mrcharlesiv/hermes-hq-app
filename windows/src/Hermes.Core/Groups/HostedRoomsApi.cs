using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Questions;
using Hermes.Core.Rpc;

namespace Hermes.Core.Groups;

/// [hosted] Shared purpose, notes, and routing for a hosted group chat (`groups.context`, Hermes 0.23.2+).
public sealed record HostedRoomContext(string Purpose = "", string Notes = "", string Routing = "everyone", string LeadMemberId = "")
{
    public const int MaxNotesBytes = 4096;
    public const int MaxPurposeChars = 500;

    public static int NotesUtf8Count(string notes) => Encoding.UTF8.GetByteCount(notes.Trim());

    /// Collapses internal whitespace, trims, and caps purpose at 500 characters (matching upstream `groups.context`).
    public static string NormalizePurpose(string purpose)
    {
        var collapsed = string.Join(' ', purpose.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return collapsed.Length <= MaxPurposeChars ? collapsed : collapsed[..MaxPurposeChars];
    }

    public static HostedRoomContext? From(JsonNode? json)
    {
        if (json is not JsonObject o) return null;
        var routing = o.Str("routing") ?? "";
        return new HostedRoomContext(
            o.Str("purpose") ?? "",
            o.Str("notes") ?? "",
            routing.Length == 0 ? "everyone" : routing,
            o.Str("lead_member_id") ?? "");
    }
}

/// [hosted] One pending decision from `groups.state` (`driver_status.pending_actions`, `groups.approve`).
public sealed record HostedPendingAction(
    string Kind,
    string MemberId,
    string TaskId,
    int ExecutionGeneration,
    string? RequestId = null,
    string? Command = null,
    string? Description = null,
    IReadOnlyList<string>? Choices = null)
{
    public string Id => $"{Kind}:{TaskId}:{ExecutionGeneration}:{RequestId ?? ""}";
    public bool IsApproval => Kind == "approval";
    public IReadOnlyList<string> OfferedChoices => Choices ?? [];

    /// Allow once requires a reviewable command or description and an exact request_id.
    public bool IsReviewableApproval =>
        IsApproval && !string.IsNullOrWhiteSpace(RequestId)
        && (!string.IsNullOrWhiteSpace(Command) || !string.IsNullOrWhiteSpace(Description));

    public static HostedPendingAction? From(JsonNode? json)
    {
        if (json is not JsonObject o) return null;
        var kind = o.Str("kind");
        var memberId = o.Str("member_id");
        var taskId = o.Str("task_id");
        var generation = o.Int("execution_generation");
        if (string.IsNullOrEmpty(kind) || string.IsNullOrEmpty(memberId) || string.IsNullOrEmpty(taskId)
            || generation is not { } g || g < 1) return null;
        var approval = o.Obj("approval");
        var requestId = o.Str("request_id") ?? approval.Str("request_id") ?? approval.Str("prompt_id");
        var choices = (approval.Arr("choices") ?? []).Select(J.AsString).Where(s => !string.IsNullOrEmpty(s)).OfType<string>().ToList();
        return new HostedPendingAction(
            kind, memberId, taskId, (int)g,
            string.IsNullOrWhiteSpace(requestId) ? null : requestId.Trim(),
            approval.Str("command"),
            approval.Str("description"),
            choices);
    }
}

/// [hosted] A discussion paused at its round limit (`room.activity` `status == "bounded"`, resumed by `groups.continue`).
public sealed record HostedRoomPause(string DiscussionEventId, string? ThreadId = null);

/// Parsed `groups.changed` WebSocket payload (Hermes 0.23.4+).
public sealed record GroupsChangedPayload(IReadOnlyList<string>? RoomIds, string? BroadcastId)
{
    public static GroupsChangedPayload From(JsonNode? json)
    {
        var ids = json.Arr("room_ids")?.Select(J.AsString).Where(s => !string.IsNullOrEmpty(s)).OfType<string>().ToList();
        var broadcastId = json.Str("broadcast_id");
        return new GroupsChangedPayload(ids is { Count: > 0 } ? ids : null, string.IsNullOrWhiteSpace(broadcastId) ? null : broadcastId);
    }
}

/// Deduplicates `groups.changed` frames sharing the same `broadcast_id` across sockets.
public sealed class GroupsChangedDeduper
{
    private readonly List<string> _seen = [];
    private const int Cap = 128;

    public bool ShouldHandle(GroupsChangedPayload payload)
    {
        if (string.IsNullOrEmpty(payload.BroadcastId)) return true;
        if (_seen.Contains(payload.BroadcastId)) return false;
        _seen.Add(payload.BroadcastId);
        if (_seen.Count > Cap) _seen.RemoveRange(0, _seen.Count - Cap);
        return true;
    }
}

/// Hosted group RPC controls (`groups.approve`, `groups.continue`, `groups.context`) and per-profile approval mode
/// (`config.get` / `config.set` scoped to `profile`, Hermes 0.23.2–0.23.5).
public sealed class HostedRoomsApi(Func<string, JsonObject, TimeSpan, CancellationToken, Task<JsonNode>> call)
{
    public HostedRoomsApi(RpcConnection rpc) : this((m, p, t, c) => rpc.RequestAsync(m, p, t, c)) { }

    public Task<JsonNode> ApproveAsync(string ownerProfile, string roomId, HostedPendingAction action, ApprovalChoice choice,
        CancellationToken ct = default)
    {
        if (!action.IsApproval || action.ExecutionGeneration < 1 || string.IsNullOrWhiteSpace(action.RequestId))
            throw new InvalidOperationException("This group chat approval is no longer available.");
        if (choice is not (ApprovalChoice.Once or ApprovalChoice.Deny))
            throw new InvalidOperationException("Group approvals only support Allow Once or Deny.");
        var wireChoice = choice.Wire();
        if (action.OfferedChoices.Count > 0 && !action.OfferedChoices.Contains(wireChoice))
            throw new InvalidOperationException("That choice is not offered for this approval.");
        if (choice == ApprovalChoice.Once && !action.IsReviewableApproval)
            throw new InvalidOperationException("Allow once requires a reviewable command or description.");
        var p = new JsonObject
        {
            ["profile"] = ownerProfile,
            ["room_id"] = roomId,
            ["member_id"] = action.MemberId,
            ["task_id"] = action.TaskId,
            ["execution_generation"] = action.ExecutionGeneration,
            ["choice"] = wireChoice,
            ["request_id"] = action.RequestId,
        };
        return call("groups.approve", p, TimeSpan.FromSeconds(20), ct);
    }

    public Task<JsonNode> ContinueDiscussionAsync(string ownerProfile, string roomId, string discussionEventId,
        CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(discussionEventId))
            throw new ArgumentException("discussion_event_id is required.", nameof(discussionEventId));
        return call("groups.continue", new JsonObject
        {
            ["profile"] = ownerProfile,
            ["room_id"] = roomId,
            ["discussion_event_id"] = discussionEventId,
        }, TimeSpan.FromSeconds(20), ct);
    }

    public async Task<HostedRoomContext> SetContextAsync(string ownerProfile, string roomId, string purpose, string notes,
        string? routing = null, string? leadMemberId = null, string? eventId = null, CancellationToken ct = default)
    {
        if (HostedRoomContext.NotesUtf8Count(notes) > HostedRoomContext.MaxNotesBytes)
            throw new ArgumentException($"Shared notes exceed {HostedRoomContext.MaxNotesBytes} UTF-8 bytes.", nameof(notes));
        var normalizedPurpose = HostedRoomContext.NormalizePurpose(purpose);
        var p = new JsonObject
        {
            ["profile"] = ownerProfile,
            ["room_id"] = roomId,
            ["event_id"] = string.IsNullOrWhiteSpace(eventId) ? Guid.NewGuid().ToString("D") : eventId,
            ["purpose"] = normalizedPurpose,
            ["notes"] = notes,
        };
        if (!string.IsNullOrWhiteSpace(routing)) p["routing"] = routing;
        if (leadMemberId != null) p["lead_member_id"] = leadMemberId;
        var res = await call("groups.context", p, TimeSpan.FromSeconds(20), ct);
        return HostedRoomContext.From(res.Get("context"))
            ?? new HostedRoomContext(normalizedPurpose, notes, routing ?? "everyone", leadMemberId ?? "");
    }

    /// Reads one member profile's `approvals.mode` (`config.get`, scoped to `profile` per Hermes 0.23.5 #125969).
    public async Task<string> GetApprovalModeAsync(string profile, CancellationToken ct = default)
    {
        var p = new JsonObject { ["key"] = "approvals.mode" };
        var trimmed = profile.Trim();
        if (trimmed.Length > 0) p["profile"] = trimmed;
        var res = await call("config.get", p, TimeSpan.FromSeconds(15), ct);
        var mode = res.Str("value")?.Trim().ToLowerInvariant() ?? "";
        return mode is "manual" or "smart" or "off" ? mode : "manual";
    }

    /// Writes one member profile's `approvals.mode` (`config.set`, scoped to `profile` per Hermes 0.23.5 #125969).
    public async Task<string> SetApprovalModeAsync(string profile, string mode, CancellationToken ct = default)
    {
        var normalized = mode.Trim().ToLowerInvariant();
        var p = new JsonObject { ["key"] = "approvals.mode", ["value"] = normalized };
        var trimmed = profile.Trim();
        if (trimmed.Length > 0) p["profile"] = trimmed;
        var res = await call("config.set", p, TimeSpan.FromSeconds(15), ct);
        var kept = res.Str("value")?.Trim().ToLowerInvariant() ?? normalized;
        return kept is "manual" or "smart" or "off" ? kept : normalized;
    }
}
