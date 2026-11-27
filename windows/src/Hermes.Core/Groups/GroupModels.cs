using System.Text.Json.Nodes;

namespace Hermes.Core.Groups;

// [groups] A group chat ("room") as the app keeps it (HermesKit/Groups/GroupModels.swift; docs/spec/3x-groups.md §3.2).
// Field names are the web's, so the gateway mirror and the device file read the same way. The Swift types are value
// structs: these are classes with Clone(), and every reader that keeps one takes a copy.

public enum GroupAuthorKind { Member, User }

public sealed record GroupAuthor(GroupAuthorKind Kind, string Name, string? Source = null, string? Gateway = null)
{
    public static readonly GroupAuthor You = new(GroupAuthorKind.User, "You");
    public static string Wire(GroupAuthorKind kind) => kind == GroupAuthorKind.User ? "user" : "member";
    public static GroupAuthorKind? Read(string? raw) => raw switch { "user" => GroupAuthorKind.User, "member" => GroupAuthorKind.Member, _ => null };
}

public sealed record GroupMessage(string? Id, double At, GroupAuthor From, string Text, string? Thread = null, bool? Truncated = null)
{
    public string ThreadKey => GroupKeys.Thread(Thread);
}

/// A saved member descriptor. Unknown keys are kept in `Raw` and written back untouched.
public sealed class GroupMember
{
    public string Name { get; set; }
    public string? Handle { get; set; }
    public string? Title { get; set; }
    public bool SourceScoped { get; set; }
    public string? ConnectionId { get; set; }
    public string? ConnectionLabel { get; set; }
    public JsonObject Raw { get; set; } = [];

    public GroupMember(string name, string? handle = null, string? title = null)
    {
        Name = name;
        Handle = handle;
        Title = title;
        Raw = new JsonObject { ["name"] = name };
        if (handle != null) Raw["handle"] = handle;
    }

    /// A descriptor as the mirror carries it; null without a usable name.
    public static GroupMember? FromJson(JsonNode? json)
    {
        if (json is not JsonObject o || J.AsString(o.Get("name"))?.Trim() is not { Length: > 0 } name) return null;
        if (o.Get("name") is not JsonValue nv || !nv.TryGetValue(out string? _)) return null;
        return new GroupMember(name)
        {
            Handle = Str(o, "handle"), Title = Str(o, "title"), SourceScoped = o.Get("sourceScoped") is JsonValue b && b.TryGetValue(out bool v) && v,
            ConnectionId = Str(o, "connectionId"), ConnectionLabel = Str(o, "connectionLabel"), Raw = (JsonObject)o.DeepClone(),
        };
    }

    internal static string? Str(JsonNode? o, string key) => o.Get(key) is JsonValue v && v.TryGetValue(out string? s) ? s : null;

    /// The descriptor for the mirror: its raw keys as read, the name (and handle) current.
    public JsonObject Json
    {
        get
        {
            var o = (JsonObject)Raw.DeepClone();
            o["name"] = Name;
            if (!string.IsNullOrEmpty(Handle)) o["handle"] = Handle;
            if (SourceScoped) o["sourceScoped"] = true;
            return o;
        }
    }

    /// The device file's form (Swift's synthesized Codable: every stored property).
    internal JsonObject DeviceJson()
    {
        var o = new JsonObject { ["name"] = Name, ["sourceScoped"] = SourceScoped, ["raw"] = Raw.DeepClone() };
        if (Handle != null) o["handle"] = Handle;
        if (Title != null) o["title"] = Title;
        if (ConnectionId != null) o["connectionId"] = ConnectionId;
        if (ConnectionLabel != null) o["connectionLabel"] = ConnectionLabel;
        return o;
    }

    internal static GroupMember? FromDeviceJson(JsonNode? json)
    {
        if (Str(json, "name") is not { } name) return null;
        return new GroupMember(name)
        {
            Handle = Str(json, "handle"), Title = Str(json, "title"), SourceScoped = json.Bool("sourceScoped") == true,
            ConnectionId = Str(json, "connectionId"), ConnectionLabel = Str(json, "connectionLabel"),
            Raw = json.Obj("raw")?.DeepClone() as JsonObject ?? new JsonObject { ["name"] = name },
        };
    }

    public string Key => GroupKeys.MemberKey(this);

    public GroupMember Clone() => new(Name)
    {
        Handle = Handle, Title = Title, SourceScoped = SourceScoped, ConnectionId = ConnectionId, ConnectionLabel = ConnectionLabel,
        Raw = (JsonObject)Raw.DeepClone(),
    };

    public bool Same(GroupMember other) => Name == other.Name && Handle == other.Handle && Title == other.Title
        && SourceScoped == other.SourceScoped && ConnectionId == other.ConnectionId && ConnectionLabel == other.ConnectionLabel
        && JsonNode.DeepEquals(Raw, other.Raw);
}

public sealed record GroupHold(double At, string? ByMessageId = null, string? Thread = null);

/// A turn that timed out and may still land (§6.7).
public sealed record GroupStranded(int Before, string Thread, double At, string? Stored = null);

/// A turn a member was asked and has not answered yet, saved the moment its prompt is accepted (see the Swift).
public sealed record GroupAsking(int Before, string Thread, double At, string? Stored, string MarkKey, string? AnchorId, int AnchorCount);

public sealed record GroupTurnState(string Name, string Thread, bool WaitingOnUser = false);

/// [hosted] A group chat Hermes itself runs (`groups.*`). Never in the mirror.
public sealed record HostedRoomRef(string Owner, string RoomId, int Cursor = 0, int Latest = 0, int Revision = 0, int? Epoch = null);

public sealed class GroupRoom
{
    public string Name { get; set; }
    public string? RoomId { get; set; }
    public HostedRoomRef? Hosted { get; set; }
    public List<GroupMessage> Log { get; set; } = [];
    /// "<thread>::<memberKey>" → entries of the room log the member has seen (an index into `Log`).
    public Dictionary<string, int> Watermarks { get; set; } = [];
    public List<GroupMember> Members { get; set; } = [];
    public string? Image { get; set; }
    public bool HoldDetection { get; set; } = true;
    public Dictionary<string, GroupHold> Holds { get; set; } = [];
    public Dictionary<string, List<string>> HeldMessages { get; set; } = [];
    public Dictionary<string, string> Sessions { get; set; } = [];
    public Dictionary<string, GroupStranded> Stranded { get; set; } = [];
    public Dictionary<string, GroupAsking> Asking { get; set; } = [];
    public int SyncRevision { get; set; }
    public int Omitted { get; set; }
    public JsonObject Extra { get; set; } = [];
    // This device only (D9), never in the mirror:
    public bool Pinned { get; set; }
    public string? SectionId { get; set; }
    public int? RosterOrder { get; set; }
    public double? PinnedAt { get; set; }
    public bool Hidden { get; set; }
    public Dictionary<string, string> Undelivered { get; set; } = [];
    public List<string> Removed { get; set; } = [];
    // Runtime only, never saved:
    public Guid Uid { get; set; } = Guid.NewGuid();
    public int Epoch { get; set; }
    public bool Running { get; set; }
    public GroupTurnState? Turn { get; set; }
    public int? StoppedEpoch { get; set; }

    public GroupRoom(string name, string? roomId = null)
    {
        Name = name;
        RoomId = roomId;
    }

    public string Key => Hosted is { } h ? GroupKeys.HostedKey(h.Owner, h.RoomId) : GroupKeys.RoomKey(RoomId, Name);
    public bool IsHosted => Hosted != null;
    public double LastAt => Log.Count > 0 ? Log[^1].At : 0;

    public GroupRoom Clone()
    {
        var c = (GroupRoom)MemberwiseClone();
        c.Log = [.. Log];
        c.Watermarks = new(Watermarks);
        c.Members = [.. Members.Select(m => m.Clone())];
        c.Holds = new(Holds);
        c.HeldMessages = HeldMessages.ToDictionary(kv => kv.Key, kv => kv.Value.ToList());
        c.Sessions = new(Sessions);
        c.Stranded = new(Stranded);
        c.Asking = new(Asking);
        c.Extra = (JsonObject)Extra.DeepClone();
        c.Undelivered = new(Undelivered);
        c.Removed = [.. Removed];
        return c;
    }

    /// Swift's `==` on the struct (GroupRuntimeID always compares equal, so the uid is left out).
    public bool Same(GroupRoom o) =>
        Name == o.Name && RoomId == o.RoomId && Hosted == o.Hosted && Log.SequenceEqual(o.Log) && DictEq(Watermarks, o.Watermarks)
        && Members.Count == o.Members.Count && Members.Zip(o.Members).All(p => p.First.Same(p.Second)) && Image == o.Image
        && HoldDetection == o.HoldDetection && DictEq(Holds, o.Holds)
        && HeldMessages.Count == o.HeldMessages.Count && HeldMessages.All(kv => o.HeldMessages.TryGetValue(kv.Key, out var v) && v.SequenceEqual(kv.Value))
        && DictEq(Sessions, o.Sessions) && DictEq(Stranded, o.Stranded) && DictEq(Asking, o.Asking) && SyncRevision == o.SyncRevision
        && Omitted == o.Omitted && JsonNode.DeepEquals(Extra, o.Extra) && Pinned == o.Pinned && SectionId == o.SectionId
        && RosterOrder == o.RosterOrder && PinnedAt == o.PinnedAt && Hidden == o.Hidden && DictEq(Undelivered, o.Undelivered)
        && Removed.SequenceEqual(o.Removed) && Epoch == o.Epoch && Running == o.Running && Turn == o.Turn && StoppedEpoch == o.StoppedEpoch;

    private static bool DictEq<T>(Dictionary<string, T> a, Dictionary<string, T> b) =>
        a.Count == b.Count && a.All(kv => b.TryGetValue(kv.Key, out var v) && EqualityComparer<T>.Default.Equals(v, kv.Value));

    /// At launch: every turn the last run left unanswered becomes a late reply to collect (§6.7, stress R1).
    public void RecoverInterruptedTurns()
    {
        foreach (var (member, turn) in Asking)
        {
            var byId = turn.AnchorId is { } id ? Log.FindLastIndex(e => e.Id == id) : -1;
            var anchor = turn.AnchorId != null && byId >= 0 ? byId : Math.Min(turn.AnchorCount, Log.Count) - 1;
            Watermarks[turn.MarkKey] = Math.Max(Watermarks.GetValueOrDefault(turn.MarkKey), anchor + 1);
            if (!Stranded.ContainsKey(member)) Stranded[member] = new GroupStranded(turn.Before, turn.Thread, turn.At, turn.Stored);
        }
        Asking = [];
    }

    /// Stored log bounds (`HB/group-chat.ts:1410-1426`): each text at most 8,000 characters, the log trimmed from its
    /// head to 400 entries and 256,000 characters. Watermarks index the log, so they move with the trim.
    public void EnforceBounds()
    {
        var dropped = 0;
        if (Log.Count > GroupLimits.LogRetain) dropped = Log.Count - GroupLimits.LogRetain;
        var chars = 0;
        var keepFrom = Log.Count;
        for (var index = Log.Count - 1; index >= dropped; index--)
        {
            chars += Log[index].Text.Length;
            if (chars > GroupLimits.LogRetainChars && index < Log.Count - 1) break;
            keepFrom = index;
        }
        dropped = Math.Max(dropped, Math.Min(keepFrom, Math.Max(0, Log.Count - 1)));
        if (dropped <= 0) return;
        Log.RemoveRange(0, dropped);
        foreach (var key in Watermarks.Keys.ToList()) Watermarks[key] = Math.Max(0, Watermarks[key] - dropped);
    }

    // The device file (Swift's CodingKeys; runtime fields are never written).

    private static JsonObject Entry(GroupMessage e)
    {
        var from = new JsonObject { ["kind"] = GroupAuthor.Wire(e.From.Kind), ["name"] = e.From.Name };
        if (e.From.Source != null) from["source"] = e.From.Source;
        if (e.From.Gateway != null) from["gateway"] = e.From.Gateway;
        var o = new JsonObject { ["at"] = e.At, ["from"] = from, ["text"] = e.Text };
        if (e.Id != null) o["id"] = e.Id;
        if (e.Thread != null) o["thread"] = e.Thread;
        if (e.Truncated != null) o["truncated"] = e.Truncated;
        return o;
    }

    private static GroupMessage? ReadEntry(JsonNode? n)
    {
        if (GroupMember.Str(n, "text") is not { } text || n.Obj("from") is not { } from || GroupAuthor.Read(GroupMember.Str(from, "kind")) is not { } kind
            || GroupMember.Str(from, "name") is not { } name || GroupPrompt.Number(n.Get("at")) is not { } when) return null;
        return new GroupMessage(GroupMember.Str(n, "id"), when, new GroupAuthor(kind, name, GroupMember.Str(from, "source"), GroupMember.Str(from, "gateway")),
            text, GroupMember.Str(n, "thread"), n.Get("truncated") is JsonValue t && t.TryGetValue(out bool tb) ? tb : null);
    }

    public JsonObject ToDeviceJson()
    {
        var o = new JsonObject
        {
            ["name"] = Name,
            ["log"] = new JsonArray([.. Log.Select(e => (JsonNode)Entry(e))]),
            ["watermarks"] = Obj(Watermarks, v => v),
            ["members"] = new JsonArray([.. Members.Select(m => (JsonNode)m.DeviceJson())]),
            ["holdDetection"] = HoldDetection,
            ["holds"] = Obj(Holds, h => { var x = new JsonObject { ["at"] = h.At }; if (h.ByMessageId != null) x["byMessageId"] = h.ByMessageId; if (h.Thread != null) x["thread"] = h.Thread; return x; }),
            ["heldMessages"] = Obj(HeldMessages, l => new JsonArray([.. l.Select(s => (JsonNode)s)])),
            ["sessions"] = Obj(Sessions, v => v),
            ["stranded"] = Obj(Stranded, s => { var x = new JsonObject { ["before"] = s.Before, ["thread"] = s.Thread, ["at"] = s.At }; if (s.Stored != null) x["stored"] = s.Stored; return x; }),
            ["asking"] = Obj(Asking, a =>
            {
                var x = new JsonObject { ["before"] = a.Before, ["thread"] = a.Thread, ["at"] = a.At, ["markKey"] = a.MarkKey, ["anchorCount"] = a.AnchorCount };
                if (a.Stored != null) x["stored"] = a.Stored;
                if (a.AnchorId != null) x["anchorId"] = a.AnchorId;
                return x;
            }),
            ["syncRevision"] = SyncRevision, ["omitted"] = Omitted, ["extra"] = Extra.DeepClone(), ["pinned"] = Pinned, ["hidden"] = Hidden,
            ["undelivered"] = Obj(Undelivered, v => v), ["removed"] = new JsonArray([.. Removed.Select(s => (JsonNode)s)]),
        };
        if (RoomId != null) o["roomId"] = RoomId;
        if (Image != null) o["image"] = Image;
        if (SectionId != null) o["sectionId"] = SectionId;
        if (RosterOrder != null) o["rosterOrder"] = RosterOrder;
        if (PinnedAt != null) o["pinnedAt"] = PinnedAt;
        if (Hosted is { } h)
        {
            var x = new JsonObject { ["owner"] = h.Owner, ["roomId"] = h.RoomId, ["cursor"] = h.Cursor, ["latest"] = h.Latest, ["revision"] = h.Revision };
            if (h.Epoch != null) x["epoch"] = h.Epoch;
            o["hosted"] = x;
        }
        return o;
    }

    private static JsonObject Obj<T>(Dictionary<string, T> d, Func<T, JsonNode?> f)
    {
        var o = new JsonObject();
        foreach (var (k, v) in d) o[k] = f(v);
        return o;
    }

    private static int? IntOf(JsonNode? n) => GroupPrompt.Number(n) is { } d && d == Math.Floor(d) ? (int)d : null;

    /// `init(from:)`: only `name` is required; every other field that is missing or damaged takes its default.
    public static GroupRoom? FromDeviceJson(JsonNode? json)
    {
        if (GroupMember.Str(json, "name") is not { } name) return null;
        var r = new GroupRoom(name, GroupMember.Str(json, "roomId"));
        T? Map<T>(string key, Func<JsonObject, T?> f) where T : class => json.Obj(key) is { } o ? f(o) : null;
        Dictionary<string, TV>? All<TV>(JsonObject o, Func<JsonNode?, TV?> f) where TV : notnull
        {
            var d = new Dictionary<string, TV>();
            foreach (var (k, v) in o) { if (f(v) is { } x) d[k] = x; else return null; }   // one bad value fails the whole key, as Codable does
            return d;
        }
        if (json.Arr("log") is { } log) { var entries = log.Select(ReadEntry).ToList(); if (entries.All(e => e != null)) r.Log = entries!; }
        if (json.Obj("watermarks") is { } wm && wm.All(kv => IntOf(kv.Value) != null)) r.Watermarks = wm.ToDictionary(kv => kv.Key, kv => IntOf(kv.Value)!.Value);
        if (json.Arr("members") is { } ms) { var list = ms.Select(FromDeviceJsonMember).ToList(); if (list.All(m => m != null)) r.Members = list!; }
        r.Image = GroupMember.Str(json, "image");
        r.HoldDetection = json.Get("holdDetection") is JsonValue hd && hd.TryGetValue(out bool hdb) ? hdb : true;
        r.Holds = Map("holds", o => All(o, n => GroupPrompt.Number(n.Get("at")) is { } at
            ? new GroupHold(at, GroupMember.Str(n, "byMessageId"), GroupMember.Str(n, "thread")) : null)) ?? [];
        r.HeldMessages = Map("heldMessages", o => All(o, n => n is JsonArray a && a.All(x => x is JsonValue v && v.TryGetValue(out string? _))
            ? a.Select(x => x!.GetValue<string>()).ToList() : null)) ?? [];
        r.Sessions = Map("sessions", o => All(o, n => n is JsonValue v && v.TryGetValue(out string? s) ? s : null)) ?? [];
        r.Stranded = Map("stranded", o => All(o, n => IntOf(n.Get("before")) is { } b && GroupMember.Str(n, "thread") is { } t && GroupPrompt.Number(n.Get("at")) is { } at
            ? new GroupStranded(b, t, at, GroupMember.Str(n, "stored")) : null)) ?? [];
        r.Asking = Map("asking", o => All(o, n => IntOf(n.Get("before")) is { } b && GroupMember.Str(n, "thread") is { } t && GroupPrompt.Number(n.Get("at")) is { } at
            && GroupMember.Str(n, "markKey") is { } mk && IntOf(n.Get("anchorCount")) is { } ac
            ? new GroupAsking(b, t, at, GroupMember.Str(n, "stored"), mk, GroupMember.Str(n, "anchorId"), ac) : null)) ?? [];
        r.SyncRevision = IntOf(json.Get("syncRevision")) ?? 0;
        r.Omitted = IntOf(json.Get("omitted")) ?? 0;
        r.Extra = json.Obj("extra")?.DeepClone() as JsonObject ?? [];
        r.Pinned = json.Get("pinned") is JsonValue p && p.TryGetValue(out bool pb) && pb;
        r.SectionId = GroupMember.Str(json, "sectionId");
        r.RosterOrder = IntOf(json.Get("rosterOrder"));
        r.PinnedAt = GroupPrompt.Number(json.Get("pinnedAt"));
        r.Hidden = json.Get("hidden") is JsonValue hv && hv.TryGetValue(out bool hb) && hb;
        r.Undelivered = Map("undelivered", o => All(o, n => n is JsonValue v && v.TryGetValue(out string? s) ? s : null)) ?? [];
        if (json.Arr("removed") is { } rm && rm.All(x => x is JsonValue v && v.TryGetValue(out string? _))) r.Removed = [.. rm.Select(x => x!.GetValue<string>())];
        if (json.Obj("hosted") is { } ho && GroupMember.Str(ho, "owner") is { } owner && GroupMember.Str(ho, "roomId") is { } rid)
            r.Hosted = new HostedRoomRef(owner, rid, IntOf(ho.Get("cursor")) ?? 0, IntOf(ho.Get("latest")) ?? 0, IntOf(ho.Get("revision")) ?? 0, IntOf(ho.Get("epoch")));
        return r;
    }

    private static GroupMember? FromDeviceJsonMember(JsonNode? n) => GroupMember.FromDeviceJson(n);
}

public static class GroupLimits
{
    public const int MaxMembers = 6, MinMembers = 2;
    public const int MaxRounds = 3, MaxMessages = 10, MaxContinuations = 2;
    public const int HistoryLimit = 200, HistoryChars = 32_000, HistoryLineChars = 8_000;
    public const int LogRetain = 400, LogRetainChars = 256_000;
    public const int NameMax = 64;
    public const int SyncLog = 16, SyncText = 1_200, SyncBytes = 48_000, SyncImage = 24_000, SyncTombstones = 64;
    public const int ActivityMax = 50;
    public const int RemovedMax = 64;
    public const string TruncationMark = "… [truncated]";
}

/// One line of a room's Activity page (`HB/group-activity.ts`); runtime only.
public enum GroupActivityKind { Queued, Working, Replied, Passed, TimedOut, Failed, Cancelled, Settled, Capped, Delivered, Held, Stopped }

public sealed record GroupActivityEvent(GroupActivityKind Kind, string Member, string? Detail, double At, int Epoch, string? Thread = null);

/// A seated member as the engine and the screens use it: the roster's bot when it is there, else the saved descriptor.
public sealed record GroupSeat(string Key, string Name, string Display, string Handle, GroupMember Descriptor)
{
    public string? Title { get; init; }
    public IReadOnlyList<string> Friendly { get; init; } = [];
    public IReadOnlyList<string> PreviousNames { get; init; } = [];
    public JsonNode? Head { get; init; }
    /// Lives on another gateway (D2): shown, never driven.
    public bool Remote { get; init; }
    public string? RemoteLabel { get; init; }
    /// Missing from the roster (deleted, or the roster has not loaded).
    public bool Missing { get; init; }
    public bool CanDrive => !Remote && !Missing;
}

/// GroupPrompt.compact (HermesKit/Groups/GroupPrompt.swift): a text cut to `limit` UTF-16 units, the mark included.
public static partial class GroupPrompt
{
    /// A JSON number as a double, whether it was parsed or built in code (a built `JsonValue<int>` does not hand
    /// itself out as a double).
    internal static double? Number(JsonNode? n) =>
        n is JsonValue v && v.GetValueKind() == System.Text.Json.JsonValueKind.Number
        && double.TryParse(v.ToJsonString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : null;

    public static (string Text, bool Truncated) Compact(string text, int limit)
    {
        if (text.Length <= limit) return (text, false);
        var budget = Math.Max(0, limit - GroupLimits.TruncationMark.Length);
        return (text[..budget] + GroupLimits.TruncationMark, true);
    }
}
