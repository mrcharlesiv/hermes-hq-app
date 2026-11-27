using System.Globalization;
using System.Text.Json.Nodes;

namespace Hermes.Core.Groups;

// [groups] The gateway mirror of rooms (HermesKit/Groups/GroupSnapshot.swift; docs/spec/3x-groups.md §5):
// `ui_meta["hermes-bots-groups"]` on the default profile, a version-3 envelope. Build, size, normalise, merge. Pure.

/// A room as the mirror carries it.
public sealed class MirrorRoom
{
    public string Name { get; set; }
    public string? RoomId { get; set; }
    public bool HoldDetection { get; set; } = true;
    public int Revision { get; set; }
    public int Omitted { get; set; }
    public List<GroupMember> Members { get; set; } = [];
    public string? Image { get; set; }
    public List<GroupMessage> Log { get; set; } = [];
    /// Keys this app does not know, written back as read.
    public JsonObject Extra { get; set; } = [];

    public MirrorRoom(string name, string? roomId = null) { Name = name; RoomId = roomId; }

    public string Key => GroupKeys.RoomKey(RoomId, Name);
    public double LastAt => Log.Count > 0 ? Log[^1].At : 0;

    public MirrorRoom Clone() => new(Name, RoomId)
    {
        HoldDetection = HoldDetection, Revision = Revision, Omitted = Omitted, Members = [.. Members.Select(m => m.Clone())], Image = Image,
        Log = [.. Log], Extra = (JsonObject)Extra.DeepClone(),
    };

    public bool Same(MirrorRoom o) => Name == o.Name && RoomId == o.RoomId && HoldDetection == o.HoldDetection && Revision == o.Revision
        && Omitted == o.Omitted && Members.Count == o.Members.Count && Members.Zip(o.Members).All(p => p.First.Same(p.Second))
        && Image == o.Image && Log.SequenceEqual(o.Log) && JsonNode.DeepEquals(Extra, o.Extra);
}

public sealed class GroupMirror
{
    public Dictionary<string, MirrorRoom> Rooms { get; set; } = [];
    /// Tombstones: room key → revision.
    public Dictionary<string, int> Deleted { get; set; } = [];
    public double UpdatedAt { get; set; }
    /// The version read (the next write is always 3).
    public int Version { get; set; } = 3;

    public bool SameRooms(GroupMirror o) => Rooms.Count == o.Rooms.Count && Rooms.All(kv => o.Rooms.TryGetValue(kv.Key, out var r) && r.Same(kv.Value));
    public bool SameDeleted(GroupMirror o) => Deleted.Count == o.Deleted.Count && Deleted.All(kv => o.Deleted.TryGetValue(kv.Key, out var v) && v == kv.Value);
    public bool Same(GroupMirror o) => SameRooms(o) && SameDeleted(o) && UpdatedAt == o.UpdatedAt && Version == o.Version;
}

public static class GroupSnapshot
{
    public const string MetaKey = "hermes-bots-groups";
    private static readonly HashSet<string> KnownRoomKeys = ["name", "roomId", "holdDetection", "revision", "omitted", "members", "image", "log"];

    // Entry keys

    /// `id:<id>`, else the JSON of `[at, kind, name, source, thread or "legacy", text]`.
    public static string EntryKey(GroupMessage entry)
    {
        if (!string.IsNullOrEmpty(entry.Id)) return $"id:{entry.Id}";
        var thread = entry.ThreadKey;
        if (thread.StartsWith("legacy-", StringComparison.Ordinal)) thread = "legacy";
        return $"[{Number(entry.At)},\"{GroupAuthor.Wire(entry.From.Kind)}\",\"{entry.From.Name}\",\"{entry.From.Source ?? ""}\",\"{thread}\",\"{entry.Text}\"]";
    }

    /// Swift's `"\(n)"` for a Double: an integer prints without ".0" here; others in the shortest round-trip form.
    internal static string Number(double n) =>
        Math.Round(n) == n && Math.Abs(n) < 9.007e15 ? ((long)n).ToString(CultureInfo.InvariantCulture) : n.ToString("R", CultureInfo.InvariantCulture);

    // Reading

    private static string? Str(JsonNode? n, string key) => GroupMember.Str(n, key);
    private static int? IntOf(JsonNode? n) => GroupPrompt.Number(n) is { } d && double.IsFinite(d) ? (int)Math.Truncate(Math.Clamp(d, int.MinValue, int.MaxValue)) : null;
    private static bool? BoolOf(JsonNode? n) => n is JsonValue v && v.TryGetValue(out bool b) ? b : null;

    private static GroupMessage? Entry(JsonNode? raw)
    {
        if (raw is not JsonObject o || Str(o, "text") is not { } text || o.Get("from") is not JsonObject from
            || GroupAuthor.Read(Str(from, "kind")) is not { } kind) return null;
        if (GroupPrompt.Number(o.Get("at")) is not { } at || !double.IsFinite(at)) return null;
        var name = Str(from, "name") ?? (kind == GroupAuthorKind.User ? "You" : "");
        if (kind == GroupAuthorKind.Member && name.Length == 0) return null;
        var id = Str(o, "id") is { Length: > 0 } i ? GroupKeys.Prefix(i, 160) : null;
        return new GroupMessage(id, at, new GroupAuthor(kind, GroupKeys.Prefix(name, 128), Str(from, "source"), Str(from, "gateway")), text,
            Str(o, "thread") is { Length: > 0 } t ? t : null, BoolOf(o.Get("truncated")) == true ? true : null);
    }

    private static MirrorRoom? Room(JsonNode? raw, string? fallbackName)
    {
        if (raw is not JsonObject o) return null;
        var name = GroupKeys.CleanName(Str(o, "name") ?? fallbackName ?? "");
        if (name.Length == 0) return null;
        // A log that is not a list is a broken room: skipped whole, never half-read (stress D1).
        if (o.TryGetPropertyValue("log", out var logNode) && logNode != null && logNode is not JsonArray) return null;
        var room = new MirrorRoom(name)
        {
            RoomId = Str(o, "roomId") is { Length: > 0 } id ? GroupKeys.Prefix(id, 128) : null,
            HoldDetection = BoolOf(o.Get("holdDetection")) ?? true,
            Revision = Math.Max(0, IntOf(o.Get("revision")) ?? 0),
            Omitted = Math.Max(0, IntOf(o.Get("omitted")) ?? 0),
            Members = [.. (o.Get("members") as JsonArray ?? []).Select(GroupMember.FromJson).OfType<GroupMember>()],
        };
        if (Str(o, "image") is { Length: > 0 } image && image.Length <= GroupLimits.SyncImage) room.Image = image;
        var seen = new HashSet<string>();
        room.Log = Sorted([.. (o.Get("log") as JsonArray ?? []).Select(Entry).OfType<GroupMessage>().Where(e => seen.Add(EntryKey(e)))]);
        foreach (var (k, v) in o) if (!KnownRoomKeys.Contains(k)) room.Extra[k] = v?.DeepClone();
        return room;
    }

    /// `normalizeGroupChatSyncSnapshot`: any stored value → a version-3 view. Bad rooms and entries are skipped.
    public static GroupMirror Parse(JsonNode? raw)
    {
        var mirror = new GroupMirror();
        if (raw is not JsonObject o) return mirror;
        mirror.Version = IntOf(o.Get("version")) ?? 1;
        mirror.UpdatedAt = GroupPrompt.Number(o.Get("updatedAt")) ?? 0;
        var legacy = mirror.Version < 3;
        foreach (var (key, value) in o.Get("rooms") as JsonObject ?? [])
        {
            if (Room(value, legacy ? key : null) is not { } made) continue;
            if (legacy) { made.Name = GroupKeys.CleanName(key); if (made.Name.Length == 0) continue; }
            mirror.Rooms[made.Key] = made;
        }
        switch (o.Get("deleted"))
        {
            case JsonObject deleted:
                foreach (var (key, value) in deleted)
                {
                    var revision = Math.Max(0, IntOf(value) ?? 0);
                    mirror.Deleted[legacy ? $"name:{key}" : key] = mirror.Version == 1 ? 0 : revision;
                }
                break;
            case JsonArray names:
                foreach (var name in names.Select(n => n is JsonValue v && v.TryGetValue(out string? s) ? s : null).OfType<string>()) mirror.Deleted[$"name:{name}"] = 0;
                break;
        }
        return mirror;
    }

    // Building

    /// Oldest first; equal times keep their order (a stable sort).
    public static List<GroupMessage> Sorted(IEnumerable<GroupMessage> log) => [.. log.Select((e, i) => (e, i)).OrderBy(p => p.e.At).ThenBy(p => p.i).Select(p => p.e)];

    /// One room for the mirror: its last 16 entries, each text cut to 1,200.
    public static MirrorRoom Compact(GroupRoom room)
    {
        var o = new MirrorRoom(room.Name, room.RoomId)
        {
            HoldDetection = room.HoldDetection, Revision = room.SyncRevision, Members = [.. room.Members.Take(GroupLimits.MaxMembers).Select(m => m.Clone())],
        };
        if (room.Image is { } image && image.Length <= GroupLimits.SyncImage) o.Image = image;
        o.Log = [.. room.Log.Skip(Math.Max(0, room.Log.Count - GroupLimits.SyncLog)).Select(entry =>
        {
            var cut = GroupPrompt.Compact(entry.Text, GroupLimits.SyncText);
            return entry with { Text = cut.Text, Truncated = cut.Truncated ? true : entry.Truncated, From = entry.From with { Gateway = null } };
        })];
        o.Omitted = Math.Max(room.Omitted, room.Log.Count - o.Log.Count);
        o.Extra = (JsonObject)room.Extra.DeepClone();
        return o;
    }

    /// `groupChatSyncSnapshot`: this device's rooms as a mirror (rooms with an empty log are left out).
    public static GroupMirror Local(IEnumerable<GroupRoom> rooms, IReadOnlyDictionary<string, int> tombstones)
    {
        var mirror = new GroupMirror();
        // [hosted] A room Hermes runs lives on its gateway: never in the mirror.
        foreach (var room in rooms.Where(r => r.Log.Count > 0 && !r.IsHosted)) mirror.Rooms[room.Key] = Compact(room);
        mirror.Deleted = new(tombstones);
        return mirror;
    }

    private static JsonObject Json(GroupMessage entry)
    {
        var from = new JsonObject { ["kind"] = GroupAuthor.Wire(entry.From.Kind), ["name"] = GroupKeys.Prefix(entry.From.Name, 128) };
        if (!string.IsNullOrEmpty(entry.From.Source)) from["source"] = entry.From.Source;
        var o = new JsonObject { ["from"] = from, ["text"] = entry.Text, ["at"] = NumberNode(entry.At) };
        if (!string.IsNullOrEmpty(entry.Id)) o["id"] = GroupKeys.Prefix(entry.Id, 160);
        if (!string.IsNullOrEmpty(entry.Thread)) o["thread"] = entry.Thread;
        if (entry.Truncated == true) o["truncated"] = true;
        return o;
    }

    /// A whole number as an integer node (Swift writes 1700000000000, never 1.7E+12).
    private static JsonNode NumberNode(double n) => Math.Round(n) == n && Math.Abs(n) < 9.007e15 ? JsonValue.Create((long)n) : JsonValue.Create(n);

    public static JsonObject Json(MirrorRoom room)
    {
        var o = (JsonObject)room.Extra.DeepClone();
        o["name"] = GroupKeys.Prefix(room.Name, GroupLimits.NameMax);
        if (!string.IsNullOrEmpty(room.RoomId)) o["roomId"] = GroupKeys.Prefix(room.RoomId, 128);
        o["holdDetection"] = room.HoldDetection;
        o["revision"] = room.Revision;
        o["members"] = new JsonArray([.. room.Members.Take(GroupLimits.MaxMembers).Select(m => (JsonNode)m.Json)]);
        if (room.Image is { } image && image.Length <= GroupLimits.SyncImage) o["image"] = image;
        o["log"] = new JsonArray([.. room.Log.Select(e => (JsonNode)Json(e))]);
        o["omitted"] = room.Omitted;
        return o;
    }

    /// A room's bytes without its log's entries (its `log` counted as an empty list).
    private static int Frame(MirrorRoom room)
    {
        var bare = room.Clone();
        bare.Log = [];
        return PythonSize(Json(bare));
    }

    /// Bytes the way Python's `json.dumps` writes it (ASCII-escaped, ", " and ": " separators), counted as the web
    /// does (`HB/group-chat.ts:194-214`): never lower than Python's own count.
    public static int PythonSize(JsonNode? value)
    {
        switch (value)
        {
            case null: return 4;
            case JsonArray a: return 2 + a.Sum(PythonSize) + Math.Max(0, a.Count - 1) * 2;
            case JsonObject o: return 2 + o.Sum(kv => StringSize(kv.Key) + 2 + PythonSize(kv.Value)) + Math.Max(0, o.Count - 1) * 2;
            case JsonValue v:
                if (v.TryGetValue(out bool b)) return b ? 4 : 5;
                if (v.TryGetValue(out string? s)) return StringSize(s);
                if (v.GetValueKind() == System.Text.Json.JsonValueKind.Number
                    && double.TryParse(v.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d)) return Number(d).Length;
                return v.ToJsonString().Length;
            default: return 4;
        }
    }

    private static int StringSize(string s)
    {
        var total = 2;
        foreach (var unit in s)
        {
            total += unit switch
            {
                (char)0x08 or (char)0x09 or (char)0x0A or (char)0x0C or (char)0x0D or (char)0x22 or (char)0x5C or (char)0x2C or (char)0x3A => 2,
                < (char)0x20 => 6,
                <= (char)0x7F => 1,
                _ => 6,
            };
        }
        return total;
    }

    /// `groupChatSyncEnvelope`: the version-3 envelope, at most 48,000 bytes. Rooms go in newest first; a room that
    /// does not fit loses its oldest entries (down to one), then its image, then its place.
    public static (JsonObject Json, GroupMirror Kept, int Bytes) Envelope(GroupMirror mirror, double now, int limit = GroupLimits.SyncBytes)
    {
        var tombstones = mirror.Deleted.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal).Take(GroupLimits.SyncTombstones).ToList();
        var deleted = new JsonObject();
        foreach (var (key, revision) in tombstones) deleted[key] = revision;
        var baseObj = new JsonObject { ["version"] = 3, ["updatedAt"] = NumberNode(now), ["rooms"] = new JsonObject() };
        if (deleted.Count > 0) baseObj["deleted"] = deleted;
        var total = PythonSize(baseObj);
        var rooms = new JsonObject();
        var kept = new GroupMirror { Deleted = tombstones.ToDictionary(kv => kv.Key, kv => kv.Value), UpdatedAt = now, Version = 3 };
        var ranked = mirror.Rooms.Values.Where(r => r.Log.Count > 0).OrderByDescending(r => r.LastAt).ThenBy(r => r.Key, StringComparer.Ordinal).ToList();
        foreach (var source in ranked)
        {
            var room = source.Clone();
            if (room.Log.Count > GroupLimits.SyncLog)
            {
                room.Omitted += room.Log.Count - GroupLimits.SyncLog;
                room.Log = [.. room.Log.Skip(room.Log.Count - GroupLimits.SyncLog)];
            }
            var keySize = StringSize(room.Key) + 2 + 2;
            var sizes = room.Log.Select(e => PythonSize(Json(e))).ToList();
            var logSize = sizes.Sum() + Math.Max(0, sizes.Count - 1) * 2;
            var frameSize = Frame(room);
            var size = frameSize + logSize + keySize;
            var fits = total + size <= limit;
            while (!fits)
            {
                if (room.Log.Count > 1)
                {
                    var digits = Number(room.Omitted).Length;
                    room.Log.RemoveAt(0);
                    room.Omitted += 1;
                    logSize -= sizes[0] + 2;
                    sizes.RemoveAt(0);
                    frameSize += Number(room.Omitted).Length - digits;
                }
                else if (room.Image != null)
                {
                    room.Image = null;
                    frameSize = Frame(room);
                }
                else break;
                size = frameSize + logSize + keySize;
                fits = total + size <= limit;
            }
            if (!fits) continue;
            rooms[room.Key] = Json(room);
            kept.Rooms[room.Key] = room;
            total += size;
        }
        baseObj["rooms"] = rooms;
        return (baseObj, kept, total);
    }

    // Merging

    /// `mergeGroupChatSyncSnapshots`: the gateway's mirror and this device's, with the rooms this write changes or
    /// deletes stamped `writeRevision`. A room missing from one side is never deleted; only a tombstone deletes.
    public static GroupMirror Merge(GroupMirror remote, GroupMirror local, ISet<string>? changed = null, ISet<string>? deleted = null,
        IReadOnlyDictionary<string, HashSet<string>>? removed = null, int writeRevision = 0)
    {
        changed ??= new HashSet<string>();
        deleted ??= new HashSet<string>();
        var o = new GroupMirror();
        foreach (var (key, revision) in remote.Deleted) o.Deleted[key] = Math.Max(o.Deleted.GetValueOrDefault(key), revision);
        foreach (var (key, revision) in local.Deleted) o.Deleted[key] = Math.Max(o.Deleted.GetValueOrDefault(key), revision);
        foreach (var key in deleted.Where(k => !changed.Contains(k))) o.Deleted[key] = writeRevision;
        foreach (var key in remote.Rooms.Keys.Union(local.Rooms.Keys))
        {
            remote.Rooms.TryGetValue(key, out var theirs);
            local.Rooms.TryGetValue(key, out var mine);
            var room = (theirs ?? mine)!.Clone();
            if (theirs != null && mine != null)
            {
                var byKey = new Dictionary<string, GroupMessage>();
                var order = new List<string>();
                var gone = removed?.GetValueOrDefault(key) ?? [];
                foreach (var entry in theirs.Log.Concat(mine.Log))
                {
                    var entryKey = EntryKey(entry);
                    if (gone.Contains(entryKey)) continue;   // deleted on this device: not written back
                    if (!byKey.ContainsKey(entryKey)) order.Add(entryKey);
                    // The later (local) twin wins, unless it is the cut one and the other is whole.
                    if (byKey.TryGetValue(entryKey, out var held) && held.Truncated != true && entry.Truncated == true) continue;
                    byKey[entryKey] = entry;
                }
                var localRevision = changed.Contains(key) ? writeRevision : mine.Revision;
                var identity = localRevision >= theirs.Revision ? mine : theirs;
                room = identity.Clone();
                if (localRevision == theirs.Revision)
                {
                    var members = mine.Members.Select(m => m.Clone()).ToList();
                    var have = members.Select(m => m.Key).ToHashSet();
                    members.AddRange(theirs.Members.Where(m => !have.Contains(m.Key)).Select(m => m.Clone()));
                    room.Members = members;
                    room.Image = mine.Image ?? theirs.Image;
                }
                var extra = (JsonObject)theirs.Extra.DeepClone();
                foreach (var (k, v) in mine.Extra) extra[k] = v?.DeepClone();
                room.Extra = extra;
                room.Log = Sorted(order.Select(k => byKey[k]).OrderBy(e => e.At).ThenBy(EntryKey, StringComparer.Ordinal));
                room.Revision = Math.Max(localRevision, theirs.Revision);
                room.Omitted = Math.Max(theirs.Omitted, mine.Omitted);
            }
            else if (mine != null && changed.Contains(key))
            {
                room.Revision = writeRevision;
            }
            o.Rooms[key] = room;
        }
        foreach (var (key, revision) in o.Deleted.ToList())
        {
            if (!o.Rooms.TryGetValue(key, out var room)) continue;
            if (key.StartsWith("id:", StringComparison.Ordinal) || revision >= room.Revision) o.Rooms.Remove(key); else o.Deleted.Remove(key);
        }
        return o;
    }

    // Into this device's rooms

    public sealed class Applied
    {
        public List<GroupRoom> Rooms { get; set; } = [];
        /// Rooms a tombstone removed (as they were before the merge).
        public List<GroupRoom> Removed { get; } = [];
        /// Old key → new key for rooms that were re-keyed (a `name:` room gained its `roomId`).
        public Dictionary<string, string> Rekeyed { get; } = [];
        public bool Changed { get; set; }
    }

    /// The mirror merged into the device's full records: logs unioned in place (a whole local entry wins over its cut
    /// twin), identity by revision, tombstones applied. Rooms the mirror does not carry are left alone.
    public static Applied Apply(GroupMirror mirror, IEnumerable<GroupRoom> rooms, IReadOnlyDictionary<string, int>? tombstones = null,
        ISet<string>? protect = null)
    {
        var o = new Applied { Rooms = [.. rooms.Select(r => r.Clone())] };
        var deleted = new Dictionary<string, int>(mirror.Deleted);
        foreach (var (key, revision) in tombstones ?? new Dictionary<string, int>()) deleted[key] = Math.Max(deleted.GetValueOrDefault(key), revision);
        foreach (var (key, theirs) in mirror.Rooms.OrderBy(kv => kv.Key, StringComparer.Ordinal))
        {
            if (deleted.TryGetValue(key, out var tombstone) && (key.StartsWith("id:", StringComparison.Ordinal) || tombstone >= theirs.Revision)) continue;
            var index = o.Rooms.FindIndex(r => r.Key == key);
            if (index < 0 && theirs.RoomId != null)
            {
                var named = o.Rooms.FindIndex(r => r.RoomId == null && r.Name == theirs.Name);
                if (named >= 0)
                {
                    // The same room gained a roomId elsewhere: re-key it here, never show it twice.
                    o.Rekeyed[o.Rooms[named].Key] = key;
                    o.Rooms[named].RoomId = theirs.RoomId;
                    index = named;
                    o.Changed = true;
                }
            }
            if (index < 0)
            {
                o.Rooms.Add(new GroupRoom(theirs.Name, theirs.RoomId)
                {
                    Log = [.. theirs.Log], Members = [.. theirs.Members.Select(m => m.Clone())], Image = theirs.Image, HoldDetection = theirs.HoldDetection,
                    SyncRevision = theirs.Revision, Omitted = theirs.Omitted, Extra = (JsonObject)theirs.Extra.DeepClone(),
                });
                o.Changed = true;
                continue;
            }
            var room = o.Rooms[index].Clone();
            var before = o.Rooms[index];
            // A room with a change of its own waiting to be published keeps its identity until that write.
            if (theirs.Revision > room.SyncRevision && !(protect?.Contains(key) ?? false))
            {
                room.Name = theirs.Name;
                if (theirs.Members.Count > 0) room.Members = [.. theirs.Members.Select(m => m.Clone())];
                room.Image = theirs.Image;
                room.HoldDetection = theirs.HoldDetection;
                room.SyncRevision = theirs.Revision;
            }
            foreach (var (k, v) in theirs.Extra) if (!room.Extra.ContainsKey(k)) room.Extra[k] = v?.DeepClone();
            var known = new HashSet<string>();
            foreach (var entry in room.Log)
            {
                known.Add(EntryKey(entry));
                if (string.IsNullOrEmpty(entry.Id)) known.Add(EntryKey(entry with { Text = GroupPrompt.Compact(entry.Text, GroupLimits.SyncText).Text }));
            }
            known.UnionWith(room.Removed);   // deleted here: the mirror's copy is not taken in again
            var fresh = theirs.Log.Where(e => known.Add(EntryKey(e))).ToList();
            if (fresh.Count > 0)
            {
                // In place: new entries go where their time puts them; nothing already on screen is reordered.
                if (room.Log.Count > 0 && fresh.All(e => e.At >= room.Log[^1].At))
                {
                    room.Log.AddRange(Sorted(fresh));
                }
                else
                {
                    var merged = Sorted(room.Log.Concat(fresh));
                    // Watermarks index the log: an entry merged in before a mark moves the mark past it.
                    foreach (var (markKey, mark) in room.Watermarks.ToList())
                    {
                        var seen = room.Log.Take(mark).Select(EntryKey).ToHashSet();
                        var next = 0;
                        for (var offset = 0; offset < merged.Count; offset++) if (seen.Contains(EntryKey(merged[offset]))) next = offset + 1;
                        room.Watermarks[markKey] = next;
                    }
                    room.Log = merged;
                }
            }
            // `Omitted` here = entries missing before this device's first one: only a log that came from the mirror has any.
            if (before.Log.Count == 0) room.Omitted = theirs.Omitted;
            room.EnforceBounds();
            if (!room.Same(before)) { o.Rooms[index] = room; o.Changed = true; }
        }
        var keep = new List<GroupRoom>();
        foreach (var room in o.Rooms)
        {
            if (deleted.TryGetValue(room.Key, out var tombstone) && (room.Key.StartsWith("id:", StringComparison.Ordinal) || tombstone >= room.SyncRevision))
            {
                o.Removed.Add(room);
                o.Changed = true;
            }
            else keep.Add(room);
        }
        o.Rooms = keep;
        return o;
    }
}
