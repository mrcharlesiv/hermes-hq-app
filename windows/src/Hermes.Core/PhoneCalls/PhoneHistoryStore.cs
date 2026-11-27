using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace Hermes.Core.PhoneCalls;

/// Call lifecycle state machine covering dialing, ringing, connected, hold, ending, and ended.
public enum PhoneCallState
{
    Dialing,
    Ringing,
    Connected,
    OnHold,
    Ending,
    Ended,
}

public enum PhoneResultDeliveryState
{
    None,
    Pending,
    Delivered,
    Skipped,
}

/// Complete record for one active or completed phone call.
public sealed record PhoneCallRecord
{
    public required string Id { get; init; }
    public required string AccountId { get; init; }
    public required string To { get; init; }
    public string? TargetName { get; init; }
    public required string Goal { get; init; }
    public PhoneVoicemailChoice Voicemail { get; init; } = PhoneVoicemailChoice.HangUp;
    public PhoneCallState State { get; init; } = PhoneCallState.Dialing;
    public bool IsMuted { get; init; }
    public bool IsOnHold => State == PhoneCallState.OnHold;
    public string? CallControlId { get; init; }
    public string? CallLegId { get; init; }
    public string? ConversationId { get; init; }
    public DateTimeOffset StartedAt { get; init; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? AnsweredAt { get; init; }
    public DateTimeOffset? EndedAt { get; init; }
    public PhoneOutcome? Outcome { get; init; }
    public PhoneLocalEnd LocalEnd { get; init; } = PhoneLocalEnd.None;
    public string? Summary { get; init; }
    public IReadOnlyList<PhoneTranscriptLine> Lines { get; init; } = [];
    public PhoneQuestion? PendingQuestion { get; init; }
    public IReadOnlyList<PhoneQA> QAs { get; init; } = [];
    public PhoneResultDeliveryState ResultDelivery { get; init; } = PhoneResultDeliveryState.None;
    public string? ChatProfile { get; init; }
    public string? ChatSessionId { get; init; }
    public string? Error { get; init; }
    public bool VoicemailDetected { get; init; }

    public bool IsActive => State is PhoneCallState.Dialing or PhoneCallState.Ringing or PhoneCallState.Connected or PhoneCallState.OnHold or PhoneCallState.Ending;
    public bool IsLive => State is PhoneCallState.Connected or PhoneCallState.OnHold;
    public bool IsDone => State == PhoneCallState.Ended;

    public string DisplayTarget => !string.IsNullOrWhiteSpace(TargetName) ? TargetName!.Trim() : PhoneFormatting.FormatShown(To);

    public TimeSpan Elapsed(DateTimeOffset now)
    {
        var start = AnsweredAt ?? StartedAt;
        var end = EndedAt ?? now;
        return end > start ? end - start : TimeSpan.Zero;
    }

    public JsonObject ToJson() => new()
    {
        ["id"] = Id,
        ["account_id"] = AccountId,
        ["to"] = To,
        ["target_name"] = TargetName,
        ["goal"] = Goal,
        ["voicemail"] = Voicemail == PhoneVoicemailChoice.LeaveMessage ? "leave" : "hangup",
        ["state"] = State.ToString().ToLowerInvariant(),
        ["muted"] = IsMuted,
        ["call_control_id"] = CallControlId,
        ["call_leg_id"] = CallLegId,
        ["conversation_id"] = ConversationId,
        ["started_at"] = StartedAt.ToString("O"),
        ["answered_at"] = AnsweredAt?.ToString("O"),
        ["ended_at"] = EndedAt?.ToString("O"),
        ["outcome_kind"] = Outcome?.Kind.ToString().ToLowerInvariant(),
        ["outcome_reason"] = Outcome?.Reason,
        ["local_end"] = LocalEnd.ToString().ToLowerInvariant(),
        ["summary"] = Summary,
        ["lines"] = new JsonArray([.. Lines.TakeLast(PhoneLimits.MaxLinesPerCall).Select(l => (JsonNode)l.ToJson())]),
        ["qas"] = new JsonArray([.. QAs.Select(q => (JsonNode)q.ToJson())]),
        ["result_delivery"] = ResultDelivery.ToString().ToLowerInvariant(),
        ["chat_profile"] = ChatProfile,
        ["chat_session_id"] = ChatSessionId,
        ["error"] = Error,
        ["voicemail_detected"] = VoicemailDetected,
    };

    public static PhoneCallRecord? FromJson(JsonNode? node)
    {
        if (node is not JsonObject) return null;
        var id = node.Text("id");
        var to = node.Text("to");
        var goal = node.Text("goal");
        if (id == null || to == null || goal == null) return null;

        var state = (node.Str("state")?.ToLowerInvariant()) switch
        {
            "dialing" => PhoneCallState.Dialing,
            "ringing" => PhoneCallState.Ringing,
            "connected" => PhoneCallState.Connected,
            "onhold" => PhoneCallState.OnHold,
            "ending" => PhoneCallState.Ending,
            _ => PhoneCallState.Ended,
        };
        var outcome = ParseOutcome(node.Str("outcome_kind"), node.Text("outcome_reason"));
        var localEnd = (node.Str("local_end")?.ToLowerInvariant()) switch
        {
            "youhungup" => PhoneLocalEnd.YouHungUp,
            "safetystop" => PhoneLocalEnd.SafetyStop,
            "ringtimeout" => PhoneLocalEnd.RingTimeout,
            _ => PhoneLocalEnd.None,
        };
        var delivery = (node.Str("result_delivery")?.ToLowerInvariant()) switch
        {
            "pending" => PhoneResultDeliveryState.Pending,
            "delivered" => PhoneResultDeliveryState.Delivered,
            "skipped" => PhoneResultDeliveryState.Skipped,
            _ => PhoneResultDeliveryState.None,
        };
        return new PhoneCallRecord
        {
            Id = id,
            AccountId = node.Text("account_id") ?? "default",
            To = to,
            TargetName = node.Text("target_name"),
            Goal = goal,
            Voicemail = string.Equals(node.Str("voicemail"), "leave", StringComparison.OrdinalIgnoreCase)
                ? PhoneVoicemailChoice.LeaveMessage
                : PhoneVoicemailChoice.HangUp,
            State = state,
            IsMuted = node.Bool("muted") ?? false,
            CallControlId = node.Text("call_control_id"),
            CallLegId = node.Text("call_leg_id"),
            ConversationId = node.Text("conversation_id"),
            StartedAt = PhoneCallEvent.ParseTimestamp(node.Str("started_at")) ?? DateTimeOffset.UtcNow,
            AnsweredAt = PhoneCallEvent.ParseTimestamp(node.Str("answered_at")),
            EndedAt = PhoneCallEvent.ParseTimestamp(node.Str("ended_at")),
            Outcome = outcome,
            LocalEnd = localEnd,
            Summary = node.Text("summary"),
            Lines = [.. (node.Arr("lines") ?? []).Select(PhoneTranscriptLine.FromJson).OfType<PhoneTranscriptLine>().TakeLast(PhoneLimits.MaxLinesPerCall)],
            QAs = [.. (node.Arr("qas") ?? []).Select(PhoneQA.FromJson).OfType<PhoneQA>()],
            ResultDelivery = delivery,
            ChatProfile = node.Text("chat_profile"),
            ChatSessionId = node.Text("chat_session_id"),
            Error = node.Text("error"),
            VoicemailDetected = node.Bool("voicemail_detected") ?? false,
        };
    }

    private static PhoneOutcome? ParseOutcome(string? raw, string? reason)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        return raw.ToLowerInvariant() switch
        {
            "finished" => PhoneOutcome.Finished,
            "voicemail" => PhoneOutcome.Voicemail,
            "noanswer" => PhoneOutcome.NoAnswer,
            "busy" => PhoneOutcome.Busy,
            "declined" => PhoneOutcome.Declined,
            "nosuchnumber" => PhoneOutcome.NoSuchNumber,
            "couldnotconnect" => PhoneOutcome.CouldNotConnect(reason ?? ""),
            _ => PhoneOutcome.Unknown,
        };
    }
}

public interface IPhoneHistoryStore
{
    IReadOnlyList<PhoneCallRecord> Load(string accountId);
    void Save(string accountId, IReadOnlyList<PhoneCallRecord> calls);
    void Clear(string accountId);
}

public sealed class MemoryPhoneHistoryStore : IPhoneHistoryStore
{
    private readonly Dictionary<string, List<PhoneCallRecord>> _byAccount = new(StringComparer.Ordinal);

    public IReadOnlyList<PhoneCallRecord> Load(string accountId) =>
        _byAccount.TryGetValue(accountId, out var list) ? [.. list] : [];

    public void Save(string accountId, IReadOnlyList<PhoneCallRecord> calls) =>
        _byAccount[accountId] = [.. calls.Take(PhoneLimits.MaxHistoryCalls).Select(TrimLines)];

    public void Clear(string accountId) => _byAccount.Remove(accountId);

    private static PhoneCallRecord TrimLines(PhoneCallRecord c) =>
        c.Lines.Count > PhoneLimits.MaxLinesPerCall
            ? c with { Lines = [.. c.Lines.TakeLast(PhoneLimits.MaxLinesPerCall)] }
            : c;
}

/// Disk-backed per-account call history store (`PhoneHistory.swift` port):
/// SHA-256 hashed account filename, capped at 50 calls and 300 lines per call.
public sealed class FilePhoneHistoryStore(string rootDirectory) : IPhoneHistoryStore
{
    private readonly object _gate = new();

    public string FilePathFor(string accountId)
    {
        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(accountId)));
        return Path.Combine(rootDirectory, $"phone-history-{hash[..24]}.json");
    }

    public IReadOnlyList<PhoneCallRecord> Load(string accountId)
    {
        lock (_gate)
        {
            var path = FilePathFor(accountId);
            if (!File.Exists(path)) return [];
            try
            {
                if (J.Parse(File.ReadAllText(path)) is not JsonArray arr) return [];
                return [.. arr.Select(PhoneCallRecord.FromJson).OfType<PhoneCallRecord>().Take(PhoneLimits.MaxHistoryCalls)];
            }
            catch (IOException)
            {
                return [];
            }
        }
    }

    public void Save(string accountId, IReadOnlyList<PhoneCallRecord> calls)
    {
        lock (_gate)
        {
            try
            {
                Directory.CreateDirectory(rootDirectory);
                var trimmed = calls.Take(PhoneLimits.MaxHistoryCalls)
                    .Select(c => c.Lines.Count > PhoneLimits.MaxLinesPerCall
                        ? c with { Lines = [.. c.Lines.TakeLast(PhoneLimits.MaxLinesPerCall)] }
                        : c);
                var arr = new JsonArray([.. trimmed.Select(c => (JsonNode)c.ToJson())]);
                File.WriteAllText(FilePathFor(accountId), arr.ToJsonString());
            }
            catch (IOException)
            {
                // Best-effort local persistence; keep in-memory history intact.
            }
        }
    }

    public void Clear(string accountId)
    {
        lock (_gate)
        {
            var path = FilePathFor(accountId);
            try { if (File.Exists(path)) File.Delete(path); } catch (IOException) { }
        }
    }
}
