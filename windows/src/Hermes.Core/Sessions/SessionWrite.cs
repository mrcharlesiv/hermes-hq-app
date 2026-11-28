using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Net;

namespace Hermes.Core.Sessions;

/// Session edits behind a revision fence (Hermes 0.22.3+). Port of HermesKit's SessionWrite: every rename, pin, archive,
/// unread and delete reads `GET /api/sessions/{id}/mutation-snapshot?profile=p` → {exists, runtime_revision,
/// runtime_generation} and sends that back with a fresh request id (in the PATCH body, in the DELETE query). A gateway
/// without the route (404/405, or a page that isn't the snapshot) takes the write as before. `revision_conflict` /
/// `stale_generation` reads again and sends once more. A write whose answer never came keeps its identity, so Try Again
/// replays the same request id.
public static class SessionWrite
{
    public sealed record Identity(string RequestId, long Revision, long? Generation);

    private static readonly ConcurrentDictionary<string, Identity> Pending = new();

    public static string PathOf(string id) => "/api/sessions/" + Uri.EscapeDataString(id);

    private static List<KeyValuePair<string, string>> Query(string? profile) => profile == null ? [] : [new("profile", profile)];

    /// PATCH /api/sessions/{id}?profile=p {fields…, "profile": p}.
    public static Task<RestAnswer> PatchAsync(IListsGateway gw, string id, string? profile, JsonObject fields, CancellationToken ct = default)
    {
        var body = (JsonObject)fields.DeepClone();
        if (profile != null) body["profile"] = profile;
        return FencedAsync(gw, id, profile, "PATCH", body.ToJsonString(), identity =>
        {
            var sent = (JsonObject)body.DeepClone();
            if (identity != null)
            {
                sent["request_id"] = identity.RequestId;
                sent["expected_revision"] = identity.Revision;
                if (identity.Generation is { } g) sent["expected_generation"] = g;
            }
            return gw.RestAsync(HttpMethod.Patch, PathOf(id), Query(profile), sent, ct);
        }, ct);
    }

    /// DELETE /api/sessions/{id}?profile=p (an absent chat counts as deleted).
    public static Task<RestAnswer> DeleteAsync(IListsGateway gw, string id, string? profile, CancellationToken ct = default) =>
        FencedAsync(gw, id, profile, "DELETE", "", identity =>
        {
            var q = Query(profile);
            if (identity != null)
            {
                q.Add(new("request_id", identity.RequestId));
                q.Add(new("expected_revision", identity.Revision.ToString()));
                if (identity.Generation is { } g) q.Add(new("expected_generation", g.ToString()));
            }
            return gw.RestAsync(HttpMethod.Delete, PathOf(id), q, null, ct);
        }, ct);

    private static async Task<RestAnswer> FencedAsync(IListsGateway gw, string id, string? profile, string method, string payload,
        Func<Identity?, Task<RestAnswer>> send, CancellationToken ct)
    {
        var owner = string.Join('\u001F', gw.AccountId, profile ?? "", id);
        var key = owner + "\u001F" + method + "\u001F" + payload;
        for (var attempt = 0; attempt < 2; attempt++)
        {
            if (!Pending.TryGetValue(key, out var identity))
            {
                var snap = await gw.RestAsync(HttpMethod.Get, PathOf(id) + "/mutation-snapshot", Query(profile), null, ct);
                if (snap.Status is 404 or 405) return Ensure(await send(null));
                var j = snap.Json;
                if (!snap.Ok || RosterText.Bool(j?["exists"]) is not { } exists || RosterText.Count(j!["runtime_revision"]) is not { } revision)
                    return Ensure(await send(null));
                if (!exists)
                {
                    if (method == "DELETE") return new RestAnswer(200, """{"ok":true,"already_absent":true}""");
                    throw new GatewayException("http", "The gateway answered 404.", 404, """{"detail":"not_found"}""");
                }
                identity = new Identity(Guid.NewGuid().ToString("D"), revision, RosterText.Count(j["runtime_generation"]));
                Pending[key] = identity;
            }
            RestAnswer answer;
            try { answer = await send(identity); }
            catch (GatewayException) { throw; }       // no answer: the identity stays for Try Again
            Pending.TryRemove(key, out _);
            if (answer.Ok)
            {
                foreach (var k in Pending.Keys.Where(k => k.StartsWith(owner + "\u001F"))) Pending.TryRemove(k, out _);
                return answer;
            }
            if (attempt == 0 && answer.Status == 409 && Detail(answer) is "revision_conflict" or "stale_generation") continue;
            return Ensure(answer);
        }
        throw new GatewayException("http", "The gateway answered 409.", 409, """{"detail":"revision_conflict"}""");
    }

    private static RestAnswer Ensure(RestAnswer a) =>
        a.Ok ? a : throw new GatewayException("http", Detail(a) is { Length: > 0 } d ? d : $"The gateway answered {a.Status}.", a.Status, a.Body);

    public static string? Detail(RestAnswer a) => a.Json?["detail"] is JsonValue v ? RosterText.Text(v) : null;
}

/// Which chats work and which wait on a person, by the gateway's own live-session registry (`session.active_list`).
/// Port of HermesKit/Activity/LiveStatusWatch.swift's reading: each row is `{session_key: stored id, status: "waiting" |
/// "working" | "starting" | "idle"}`; "waiting" counts once two reads in a row said so.
public sealed class LiveStatus
{
    private HashSet<string> _waitingOnce = [];
    public IReadOnlySet<string> Working { get; private set; } = new HashSet<string>();
    public IReadOnlySet<string> Waiting { get; private set; } = new HashSet<string>();

    public static Dictionary<string, string> Statuses(JsonNode? result)
    {
        var rank = new Dictionary<string, int> { ["waiting"] = 3, ["working"] = 2, ["starting"] = 1 };
        var o = new Dictionary<string, string>();
        foreach (var row in result?["sessions"] as JsonArray ?? [])
        {
            if (RosterText.Trimmed(row?["session_key"]) is not { } id || RosterText.Trimmed(row!["status"]) is not { } status) continue;
            if (!o.TryGetValue(id, out var had) || rank.GetValueOrDefault(status) > rank.GetValueOrDefault(had)) o[id] = status;
        }
        return o;
    }

    /// [WIN-OWN-TURN-ROWS] Ids whose turn this app saw end, with when (UTC): a read that went out before then still
    /// names them (LiveStatusWatch `endedAt`).
    private readonly Dictionary<string, DateTimeOffset> _endedAt = [];
    private readonly object _gate = new();

    /// [WIN-OWN-TURN-ROWS] A turn of this app's ended in this chat: its rows stop saying so now, and a read already in
    /// the air doesn't bring it back (LiveStatusWatch.turnEnded). True when the sets changed.
    public bool TurnEnded(string storedId)
    {
        lock (_gate)
        {
            _endedAt[storedId] = DateTimeOffset.UtcNow;
            _waitingOnce.Remove(storedId);
            if (!Working.Contains(storedId) && !Waiting.Contains(storedId)) return false;
            Working = Working.Where(id => id != storedId).ToHashSet();
            Waiting = Waiting.Where(id => id != storedId).ToHashSet();
            return true;
        }
    }

    /// True when the sets changed. `started`: when the read went out (an end heard after it outranks it).
    public bool Apply(IReadOnlyDictionary<string, string> statuses, DateTimeOffset? started = null)
    {
        lock (_gate) return ApplyLocked(statuses, started ?? DateTimeOffset.UtcNow);
    }

    private bool ApplyLocked(IReadOnlyDictionary<string, string> all, DateTimeOffset started)
    {
        var now = DateTimeOffset.UtcNow;
        foreach (var gone in _endedAt.Where(kv => now - kv.Value >= TimeSpan.FromSeconds(60)).Select(kv => kv.Key).ToList())
            _endedAt.Remove(gone);
        var statuses = all.Where(kv => !_endedAt.TryGetValue(kv.Key, out var ended) || ended < started)
            .ToDictionary(kv => kv.Key, kv => kv.Value);
        var saidWaiting = statuses.Where(kv => kv.Value == "waiting").Select(kv => kv.Key).ToHashSet();
        var nextWaiting = saidWaiting.Where(id => _waitingOnce.Contains(id) || Waiting.Contains(id)).ToHashSet();
        var nextWorking = statuses.Where(kv => kv.Value is "working" or "waiting").Select(kv => kv.Key).ToHashSet();
        _waitingOnce = saidWaiting;
        if (nextWaiting.SetEquals(Waiting) && nextWorking.SetEquals(Working)) return false;
        Waiting = nextWaiting;
        Working = nextWorking;
        return true;
    }

    /// One read; a gateway without the call (-32601) or a failed read keeps what was known.
    public async Task<bool> ReadAsync(IListsGateway gw, CancellationToken ct = default)
    {
        var started = DateTimeOffset.UtcNow;
        try { return Apply(Statuses(await gw.CallAsync("session.active_list", new JsonObject(), TimeSpan.FromSeconds(15), ct)), started); }
        catch (GatewayException) { return false; }
    }
}

/// What a bot lists under its row in the sidebar ([chats-under], App/Bots/BotChatsUnder.swift).
public enum BotChatsMode { Off, Active, Pinned, Recent }

public sealed record BotChatsChoice(BotChatsMode Mode, int Count)
{
    public static readonly int[] Counts = [1, 2, 3, 5];
    public static readonly BotChatsChoice Standard = new(BotChatsMode.Recent, 2);
    public static readonly BotChatsChoice Initial = new(BotChatsMode.Off, 2);

    public static string Title(BotChatsMode m) => m switch
    {
        BotChatsMode.Off => "Off", BotChatsMode.Active => "Active", BotChatsMode.Pinned => "Pinned Only", _ => "Pinned + Recent",
    };

    public static string? Detail(BotChatsMode m) => m switch
    {
        BotChatsMode.Active => "Working, waiting for you, or unread", BotChatsMode.Pinned => "Chats you pin", _ => null,
    };

    public string Summary => Mode switch
    {
        BotChatsMode.Off => "Off", BotChatsMode.Active => "Active chats", BotChatsMode.Pinned => "Pinned only", _ => $"Pinned + {Count} recent",
    };

    public string Stored => Mode == BotChatsMode.Recent ? $"recent:{Count}" : Mode.ToString().ToLowerInvariant();

    public static BotChatsChoice? Parse(string? stored)
    {
        if (stored == null) return null;
        var parts = stored.Split(':', 2);
        if (!Enum.TryParse<BotChatsMode>(parts[0], true, out var mode)) return null;
        var count = parts.Length > 1 && int.TryParse(parts[1], out var c) && Counts.Contains(c) ? c : Standard.Count;
        return new BotChatsChoice(mode, count);
    }
}

/// A manual shortcut placing an ordinary chat under its bot in the sidebar (HermesKit/Store/SessionStore+BotShortcuts.swift).
public sealed record BotChatShortcut(string Profile, string Id);

public static class BotChatsUnder
{
    public const int MaxPinned = 5;

    /// Only another chat under this bot calls for a pin icon; the "N more" link isn't a chat
    /// (App/Bots/BotChatsUnder.swift `showsPin(for:among:)`, `ac80666c3`).
    public static bool ShowsPin(SessionSummary session, IReadOnlyList<SessionSummary> shown) =>
        session.Pinned && shown.Count > 1;

    /// Resolves manual per-bot shortcut records against the live session list, preserving shortcut order.
    public static List<SessionSummary> ResolveShortcuts(
        IEnumerable<SessionSummary> sessions,
        IEnumerable<BotChatShortcut> shortcuts,
        string bot)
    {
        var byId = sessions.Where(s => s.Profile == bot && !s.Archived)
            .GroupBy(s => s.Id, StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => g.First(), StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<SessionSummary>();
        foreach (var sc in shortcuts)
        {
            if (sc.Profile == bot && seen.Add(sc.Id) && byId.TryGetValue(sc.Id, out var found))
                result.Add(found);
        }
        return result;
    }

    public static bool IsActive(SessionSummary s) => s.IsRunning || s.Unread || s.Status is SessionStatus.NeedsInput or SessionStatus.Working;

    /// The bot's manual per-bot shortcuts first, then its pinned chats (up to five), then for Pinned + Recent its newest
    /// others; `More`: its remaining non-shortcut chats not shown (App/Bots/BotChatsUnder.swift `pick`).
    public static (List<SessionSummary> Shown, int More) Pick(
        IEnumerable<SessionSummary> sessions,
        string bot,
        BotChatsChoice choice,
        IEnumerable<SessionSummary>? shortcuts = null)
    {
        var chosen = new HashSet<string>(StringComparer.Ordinal);
        var manual = shortcuts == null
            ? new List<SessionSummary>()
            : shortcuts.Where(s => s.Profile == bot && !s.Archived && chosen.Add(s.Id)).ToList();
        if (choice.Mode == BotChatsMode.Off) return (manual, 0);
        var own = sessions.Where(s => s.Profile == bot && !s.Archived && !chosen.Contains(s.Id)).ToList();
        if (choice.Mode == BotChatsMode.Active)
        {
            static int Rank(SessionSummary s) => s.Status == SessionStatus.NeedsInput ? 0 : s.IsRunning || s.Status == SessionStatus.Working ? 1 : 2;
            var active = own.Where(IsActive).OrderBy(Rank).ThenByDescending(s => s.LastActive ?? DateTimeOffset.MinValue).Take(MaxPinned).ToList();
            manual.AddRange(active);
            return (manual, own.Count - active.Count);
        }
        var shown = own.Where(s => s.Pinned).Take(MaxPinned).ToList();
        if (choice.Mode == BotChatsMode.Recent)
            shown.AddRange(own.Where(s => !s.Pinned).OrderByDescending(s => s.LastActive ?? DateTimeOffset.MinValue).Take(choice.Count));
        manual.AddRange(shown);
        return (manual, own.Count - shown.Count);
    }
}
