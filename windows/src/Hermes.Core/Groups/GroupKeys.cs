using System.Text.Json.Nodes;

namespace Hermes.Core.Groups;

// [groups] Keys and ids for rooms (HermesKit/Groups/GroupKeys.swift; docs/spec/3x-groups.md §3.2).
public static class GroupKeys
{
    /// [hosted] A room Hermes runs on its gateway: its owner profile and the gateway's room id.
    public static string HostedKey(string owner, string roomId) => $"gw:{owner}/{roomId}";

    public static string RoomKey(string? roomId, string name) => !string.IsNullOrEmpty(roomId) ? $"id:{roomId}" : $"name:{name}";

    public static string MemberKey(GroupMember member) =>
        member.SourceScoped && !string.IsNullOrEmpty(member.ConnectionId) ? $"{member.ConnectionId}::{member.Name}" : member.Name;

    public static string Thread(string? thread) => string.IsNullOrEmpty(thread) ? "legacy" : thread;

    public static string SessionKey(string thread, string memberKey) => $"thread:{thread}::{memberKey}";
    public static string WatermarkKey(string thread, string memberKey) => $"{thread}::{memberKey}";
    public static string MuteKey(string roomKey) => $"room:{roomKey}";
    public static string PinEntry(string roomKey) => $"group:{roomKey}";

    private const string Alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";

    public static string Random5() => new([.. Enumerable.Range(0, 5).Select(_ => Alphabet[Random.Shared.Next(Alphabet.Length)])]);

    /// Milliseconds since 1970 in base 36 (`Date.now().toString(36)`).
    public static string Stamp(DateTimeOffset? now = null)
    {
        var n = (now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds();
        if (n == 0) return "0";
        var chars = new List<char>();
        for (var v = Math.Abs(n); v > 0; v /= 36) chars.Insert(0, Alphabet[(int)(v % 36)]);
        return (n < 0 ? "-" : "") + new string([.. chars]);
    }

    public static string NewRoomId(DateTimeOffset? now = null) => $"r{Stamp(now)}-{Random5()}";
    public static string NewThreadId(DateTimeOffset? now = null) => $"t{Stamp(now)}-{Random5()}";
    public static string NewEntryId() => Guid.NewGuid().ToString().ToLowerInvariant();

    /// A hidden member session's title: `Group: <roomId or name> · <thread>`.
    public static string SessionTitle(GroupRoom room, string thread) => $"Group: {room.RoomId ?? room.Name} · {thread}";
    public static bool IsPlumbingTitle(string title) => title.StartsWith("Group: ", StringComparison.Ordinal);

    /// A room's name as it is saved: trimmed, at most 64 characters.
    public static string CleanName(string raw)
    {
        var trimmed = raw.Trim();
        return Prefix(trimmed, GroupLimits.NameMax).Trim();
    }

    /// Swift's `prefix(n)` counts characters (grapheme clusters).
    internal static string Prefix(string s, int n)
    {
        if (n <= 0) return "";
        var e = System.Globalization.StringInfo.GetTextElementEnumerator(s);
        var count = 0;
        while (e.MoveNext()) { if (++count > n) return s[..e.ElementIndex]; }
        return s;
    }

    internal static int Characters(string s) => new System.Globalization.StringInfo(s).LengthInTextElements;

    /// `uniqueGroupChatName`: the name itself when free, else " 2" … " 99" appended (the base cut to fit 64).
    public static string UniqueName(string raw, ISet<string> taken)
    {
        var b = CleanName(raw);
        if (!taken.Contains(b)) return b;
        for (var n = 2; n <= 99; n++)
        {
            var suffix = $" {n}";
            var candidate = Prefix(b, GroupLimits.NameMax - suffix.Length).Trim(' ') + suffix;
            if (!taken.Contains(candidate)) return candidate;
        }
        return Prefix(b, GroupLimits.NameMax - 6) + " " + Random5();
    }

    /// The rooms a bot's meta names: `groups`, else the older scalar `group`.
    public static List<string> Groups(JsonObject? meta)
    {
        if (meta.Get("groups") is JsonArray list)
        {
            var seen = new HashSet<string>();
            return [.. list.Select(x => x is JsonValue v && v.TryGetValue(out string? s) ? s : null).OfType<string>().Where(s => s.Length > 0 && seen.Add(s))];
        }
        return meta.Get("group") is JsonValue one && one.TryGetValue(out string? g) && g.Length > 0 ? [g] : [];
    }

    /// The membership patch rule (`HB/group-membership.ts:181-201`): null when nothing changes.
    public static List<string>? MembershipAdding(JsonObject? meta, string name)
    {
        var current = Groups(meta);
        return current.Contains(name) ? null : [.. current, name];
    }

    public static List<string>? MembershipRemoving(JsonObject? meta, string name)
    {
        var current = Groups(meta);
        return current.Contains(name) ? [.. current.Where(n => n != name)] : null;
    }

    public static List<string>? MembershipRenaming(JsonObject? meta, string old, string @new)
    {
        var current = Groups(meta);
        if (!current.Contains(old)) return null;
        var seen = new HashSet<string>();
        return [.. current.Select(n => n == old ? @new : n).Where(seen.Add)];
    }

    /// The `ui_meta["hermes-bots"]` patch for a new `groups` list: `group` = its first, or null.
    public static JsonObject Patch(IReadOnlyList<string> groups) => new()
    {
        ["groups"] = new JsonArray([.. groups.Select(g => (JsonNode)g)]),
        ["group"] = groups.Count > 0 ? groups[0] : null,
    };
}

/// Moving a room's mute and unread mark when the room map changes (`S/ui-bots/room-marks.ts:23-50`, `roomChanges`).
public static class GroupMarks
{
    public sealed record Changes
    {
        /// Old key → new key (a `name:` room renamed, or one that gained a `roomId`).
        public Dictionary<string, string> Moved { get; init; } = [];
        /// Keys whose marks go (a tombstone).
        public HashSet<string> Dropped { get; init; } = [];
        public bool IsEmpty => Moved.Count == 0 && Dropped.Count == 0;
    }

    public sealed record Snapshot(string Key, string Name, string? RoomId);

    public static Changes Of(IReadOnlyList<Snapshot> before, IReadOnlyList<Snapshot> after, ISet<string> tombstones,
        IReadOnlyDictionary<string, string>? renames = null)
    {
        var o = new Changes();
        var afterKeys = after.Select(s => s.Key).ToHashSet();
        var afterByName = new Dictionary<string, Snapshot>();
        foreach (var s in after) afterByName.TryAdd(s.Name, s);
        foreach (var room in before.Where(r => !afterKeys.Contains(r.Key)))
        {
            if (tombstones.Contains(room.Key)) { o.Dropped.Add(room.Key); continue; }
            if (room.RoomId != null) continue;   // an `id:` room missing from one snapshot: nothing changes
            if (renames != null && renames.TryGetValue(room.Name, out var next) && afterByName.TryGetValue(next, out var target))
                o.Moved[room.Key] = target.Key;
            else if (afterByName.TryGetValue(room.Name, out var same) && same.RoomId != null)
                o.Moved[room.Key] = same.Key;   // the same room gained a roomId
        }
        foreach (var key in tombstones.Where(k => !afterKeys.Contains(k))) o.Dropped.Add(key);
        return o;
    }
}
