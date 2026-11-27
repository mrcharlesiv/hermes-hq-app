using System.Text.Json.Nodes;

namespace Hermes.Core.Groups;

// [groups] The rooms of one signed-in account (HermesKit/Groups/GroupStore.swift; docs/spec/3x-groups.md §3.3): the
// full log on the device, the marks that never leave it (unread, pin, section, order, tombstones), who is seated right
// now, and the rows the list draws. First slice: the data and the mirror's side. The membership writes, rounds,
// hosted rooms and the device file's I/O arrive with the screens that drive them (see the WIN-32 hand-back).

/// A room as the list draws it.
public sealed record GroupRowModel(string Id, string Name, string Line, GroupRowWords.Tone Tone)
{
    public sealed record Face(string Profile, JsonNode? Head);
    public string? Image { get; init; }
    public IReadOnlyList<Face> Faces { get; init; } = [];
    public DateTimeOffset? Time { get; init; }
    public bool Unread { get; init; }
    public bool Pinned { get; init; }
    public bool Muted { get; init; }
    public int MemberCount { get; init; }
    public bool Running { get; init; }
    public string? SectionId { get; init; }
    public int? Order { get; init; }
    public double? PinnedAt { get; init; }
    public double LastAt { get; init; }
    public string Search { get; init; } = "";
    public bool Online { get; init; } = true;
    /// Hidden from the list on this device (UX study #254).
    public bool Hidden { get; init; }
}

/// One profile of the roster as the store reads it (BotStore's profile row, its bot, and its `hermes-bots` meta).
public sealed record GroupRosterProfile(string Name)
{
    /// `ui_meta["hermes-bots"]` as current (with writes in flight), where `groups` lives.
    public JsonObject? Meta { get; init; }
    public string? DisplayName { get; init; }
    public string? Title { get; init; }
    /// The bot's name when the roster has a bot for it.
    public string? BotName { get; init; }
    public JsonNode? Head { get; init; }
    public IReadOnlyList<string> PreviousNames { get; init; } = [];
}

public interface IGroupRoster
{
    /// The roster has loaded (BotStore.phase != .none).
    bool Loaded { get; }
    IReadOnlyList<GroupRosterProfile> Profiles { get; }
}

public sealed class GroupStore
{
    /// What the account's marks file holds (kind "groupmarks").
    public sealed class Marks
    {
        public List<string> Unread { get; set; } = [];
        public Dictionary<string, int> Tombstones { get; set; } = [];
        /// Names of rooms deleted here whose bots may still carry them in `groups` (never adopted back).
        public List<string> DeletedNames { get; set; } = [];
        public List<string>? OwedDeletes { get; set; }
    }

    public const string RoomsKind = "groups";
    public const string MarksKind = "groupmarks";

    public IGroupRoster? Roster { get; set; }
    public Func<bool> IsOnline { get; set; } = () => true;
    /// The mute of a room (key `room:<roomKey>`), and its move.
    public Func<string, bool> IsMuted { get; set; } = _ => false;
    public Action<string, string?> MoveMute { get; set; } = (_, _) => { };
    public Action<GroupRoom>? OnRoomRemoved { get; set; }
    /// The rooms changed (the list redraws).
    public event Action? Changed;
    /// A mutation that touches the mirror (GroupSync.Schedule).
    public Action<string>? OnMirrorChange { get; set; }

    private List<GroupRoom> rooms = [];
    public IReadOnlyList<GroupRoom> Rooms => rooms;
    public Marks MarksState { get; private set; } = new();
    private readonly Dictionary<string, List<GroupActivityEvent>> activity = [];
    public bool IsClosed { get; private set; }

    public GroupStore(IEnumerable<GroupRoom>? rooms = null, Marks? marks = null)
    {
        this.rooms = [.. (rooms ?? []).Select(r => { var c = r.Clone(); c.RecoverInterruptedTurns(); c.EnforceBounds(); return c; })];
        MarksState = marks ?? new();
    }

    public void Close() => IsClosed = true;

    public GroupRoom? Room(string key) => rooms.FirstOrDefault(r => r.Key == key);
    public bool IsUnread(string key) => MarksState.Unread.Contains(key);
    public IReadOnlyDictionary<string, int> Tombstones => MarksState.Tombstones;
    public ISet<string> RoomNames => rooms.Select(r => r.Name).ToHashSet();

    private void Notify() => Changed?.Invoke();

    /// Who is in a room right now (`groupChatMemberBots`, §3.5): the roster's bots that name it, in roster order; the
    /// saved descriptors while the roster has not loaded; the saved members of another gateway.
    public List<GroupSeat> Seated(GroupRoom room)
    {
        if (room.IsHosted) return HostedSeats(room);
        var seats = new List<GroupSeat>();
        var saved = new Dictionary<string, GroupMember>();
        foreach (var m in room.Members) saved.TryAdd(m.Name, m);
        var profiles = Roster?.Profiles ?? [];
        var loaded = Roster?.Loaded ?? false;
        if (loaded)
        {
            foreach (var profile in profiles.Where(p => GroupKeys.Groups(p.Meta).Contains(room.Name)))
            {
                var metaTitle = MetaTitle(profile);
                var handle = GroupMentions.Handle(profile.Name, saved.GetValueOrDefault(profile.Name)?.Handle);
                var descriptor = saved.GetValueOrDefault(profile.Name) is { SourceScoped: false } s ? s.Clone() : new GroupMember(profile.Name, handle);
                descriptor.Handle = handle;
                seats.Add(new GroupSeat(profile.Name, profile.Name, profile.BotName ?? metaTitle ?? profile.DisplayName ?? profile.Name, handle, descriptor)
                {
                    Title = metaTitle ?? profile.DisplayName,
                    Friendly = new[] { metaTitle, profile.Title, profile.DisplayName }.OfType<string>().ToList(),
                    PreviousNames = profile.PreviousNames, Head = profile.Head,
                });
            }
        }
        var seatedNames = seats.Select(s => s.Name).ToHashSet();
        foreach (var member in room.Members)
        {
            if (member.SourceScoped)
                seats.Add(new GroupSeat(member.Key, member.Name, member.Title ?? member.Name, member.Handle ?? member.Name, member)
                { Title = member.Title, Remote = true, RemoteLabel = member.ConnectionLabel });
            else if (!seatedNames.Contains(member.Name) && (!loaded || profiles.All(p => p.Name != member.Name)))
                // Not loaded yet, or gone from the roster: shown, never driven.
                seats.Add(new GroupSeat(member.Key, member.Name, member.Title ?? member.Name, GroupMentions.Handle(member.Name, member.Handle), member)
                { Title = member.Title, Missing = true });
        }
        return seats;
    }

    private static string? MetaTitle(GroupRosterProfile p) => GroupMember.Str(p.Meta, "title") is { } t && t.Trim(' ', '\t').Length > 0 ? t : null;

    /// [hosted] A gateway room's seats are its own roster, each the roster's bot when it is here.
    private List<GroupSeat> HostedSeats(GroupRoom room)
    {
        var loaded = Roster?.Loaded ?? false;
        return [.. room.Members.Select(member =>
        {
            if (member.SourceScoped)
                return new GroupSeat(member.Key, member.Name, member.Title ?? member.Name, member.Handle ?? member.Name, member)
                { Title = member.Title, Remote = true, RemoteLabel = member.ConnectionLabel };
            var handle = member.Handle ?? GroupMentions.Handle(member.Name, null);
            if (Roster?.Profiles.FirstOrDefault(p => p.Name == member.Name) is not { } profile)
                return new GroupSeat(member.Key, member.Name, member.Title ?? member.Name, handle, member) { Title = member.Title, Missing = loaded };
            var metaTitle = MetaTitle(profile);
            return new GroupSeat(member.Key, profile.Name, profile.BotName ?? metaTitle ?? member.Title ?? profile.DisplayName ?? profile.Name, handle, member)
            {
                Title = metaTitle ?? profile.DisplayName,
                Friendly = new[] { metaTitle, profile.Title, profile.DisplayName, member.Title }.OfType<string>().ToList(),
                PreviousNames = profile.PreviousNames, Head = profile.Head,
            };
        })];
    }

    /// Display names by profile name (for previews, the prompt's lines and Activity).
    public Dictionary<string, string> Labels(IReadOnlyList<GroupSeat> seats)
    {
        var o = new Dictionary<string, string>();
        foreach (var s in seats) o.TryAdd(s.Name, s.Display);
        foreach (var p in Roster?.Profiles ?? []) if (p.BotName is { } n) o.TryAdd(p.Name, n);
        return o;
    }

    public List<GroupRowModel> Rows()
    {
        var online = IsOnline();
        return [.. rooms.Select(room =>
        {
            var seats = Seated(room);
            var labels = Labels(seats);
            var driven = seats.Where(s => !s.Remote).ToList();
            IReadOnlyList<string> replying = room.Running && room.Turn is { } turn ? [labels.GetValueOrDefault(turn.Name) ?? turn.Name] : [];
            var line = GroupRowWords.SecondLine(room.Running && room.Turn?.WaitingOnUser == true, replying, driven.Count(s => !s.Missing), driven.Count,
                !online, room.Log.Count > 0 ? room.Log[^1] : null, labels, seats.Count);
            return new GroupRowModel(room.Key, room.Name, line.Text, line.Tone)
            {
                Image = room.Image, Faces = [.. seats.Take(3).Select(s => new GroupRowModel.Face(s.Name, s.Head))],
                Time = room.Log.Count > 0 ? DateTimeOffset.FromUnixTimeMilliseconds((long)room.Log[^1].At) : null,
                Unread = MarksState.Unread.Contains(room.Key), Pinned = room.Pinned, Muted = IsMuted(GroupKeys.MuteKey(room.Key)),
                MemberCount = seats.Count, Running = room.Running, SectionId = room.SectionId, Order = room.RosterOrder, PinnedAt = room.PinnedAt,
                LastAt = room.LastAt, Search = string.Join(" ", new[] { room.Name }.Concat(seats.Select(s => s.Display))).ToLowerInvariant(),
                Online = online, Hidden = room.Hidden,
            };
        })];
    }

    /// The rooms a bot is in (Bot Info's Group Chats, Add to Group Chat…).
    public List<GroupRoom> RoomsOf(string profile)
    {
        if (Roster == null) return [];
        var names = GroupKeys.Groups(Roster.Profiles.FirstOrDefault(p => p.Name == profile)?.Meta).ToHashSet();
        return [.. rooms.Where(r => r.IsHosted ? r.Members.Any(m => m.Name == profile && !m.SourceScoped) : names.Contains(r.Name))];
    }

    public IReadOnlyList<GroupActivityEvent> Activity(string key) =>
        Room(key) is { } room ? [.. activity.GetValueOrDefault(key, []).Where(e => e.Epoch == room.Epoch)] : [];

    public void Record(GroupActivityKind kind, string key, string member = "", string? detail = null, string? thread = null)
    {
        if (Room(key) is not { } room) return;
        var list = activity.GetValueOrDefault(key) ?? [];
        list.Add(new GroupActivityEvent(kind, member, detail, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), room.Epoch, thread));
        if (list.Count > GroupLimits.ActivityMax) list.RemoveRange(0, list.Count - GroupLimits.ActivityMax);
        activity[key] = list;
        Notify();
    }

    /// One room changed; `sync`: the change reaches the mirror (GroupSync).
    public void Update(string key, Action<GroupRoom> mutate, bool sync = true)
    {
        if (IsClosed) return;
        var index = rooms.FindIndex(r => r.Key == key);
        if (index < 0) return;
        var room = rooms[index].Clone();
        mutate(room);
        room.EnforceBounds();
        rooms[index] = room;
        Notify();
        if (sync && !room.IsHosted) OnMirrorChange?.Invoke(room.Key);
    }

    public void Append(GroupMessage message, string key)
    {
        var entry = string.IsNullOrEmpty(message.Id) ? message with { Id = GroupKeys.NewEntryId() } : message;
        Update(key, r => r.Log.Add(entry));
    }

    /// Room tiles follow the bots' tiles, newest pin last (`pinnedAt` in seconds, as the Mac stores it).
    public void SetPinned(string key, bool on) => Update(key, r => { r.Pinned = on; r.PinnedAt = on ? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 : null; }, sync: false);

    /// The room's photo (a JPEG data URL, GroupPhoto), or none; it reaches the mirror (GroupStore.swift `setImage`).
    public void SetImage(string key, string? image)
    {
        if (Room(key) is not { } room || room.Image == image) return;
        Update(key, r => r.Image = image);
    }

    public void SetSection(string key, string? sectionId) => Update(key, r => r.SectionId = sectionId, sync: false);

    /// Hide (this device only): the room leaves the list for Hidden; a hidden room is never a tile, so its pin goes too.
    public void SetHidden(string key, bool on, double? restoringPin = null) => Update(key, r =>
    {
        r.Hidden = on;
        if (on) { r.Pinned = false; r.PinnedAt = null; }
        else if (restoringPin is { } at) { r.Pinned = true; r.PinnedAt = at; }
    }, sync: false);

    public void SetUnread(string key, bool on)
    {
        if (IsClosed || MarksState.Unread.Contains(key) == on || Room(key) == null) return;
        if (on) MarksState.Unread.Add(key); else MarksState.Unread.Remove(key);
        Notify();
    }

    private void MoveMarks(string old, string? @new)
    {
        var at = MarksState.Unread.IndexOf(old);
        if (at >= 0)
        {
            MarksState.Unread.RemoveAt(at);
            if (@new != null && !MarksState.Unread.Contains(@new)) MarksState.Unread.Add(@new);
        }
        MoveMute(GroupKeys.MuteKey(old), @new == null ? null : GroupKeys.MuteKey(@new));
        if (activity.Remove(old, out var list) && @new != null) activity[@new] = list;
    }

    /// The mirror merged into the device's rooms (GroupSync, after a pull or a confirmed publish).
    public void Adopt(GroupSnapshot.Applied applied)
    {
        if (IsClosed || !applied.Changed) return;
        foreach (var (old, @new) in applied.Rekeyed) MoveMarks(old, @new);
        var next = applied.Rooms.Select(r => r.Clone()).ToList();
        foreach (var removed in applied.Removed)
        {
            MoveMarks(removed.Key, null);
            activity.Remove(removed.Key);
            if (!MarksState.DeletedNames.Contains(removed.Name)) MarksState.DeletedNames.Add(removed.Name);
        }
        // A deleted name that the mirror brought back as a live room is live again.
        var live = next.Select(r => r.Name).ToHashSet();
        var removedNames = applied.Removed.Select(r => r.Name).ToHashSet();
        MarksState.DeletedNames.RemoveAll(n => live.Contains(n) && !removedNames.Contains(n));
        foreach (var r in next) r.EnforceBounds();
        rooms = next;
        Notify();
        foreach (var removed in applied.Removed) OnRoomRemoved?.Invoke(removed);
    }

    public void Stamp(int revision, ISet<string> keys)
    {
        if (IsClosed) return;
        foreach (var r in rooms.Where(r => keys.Contains(r.Key))) r.SyncRevision = Math.Max(r.SyncRevision, revision);
    }

    public void AdoptTombstones(IReadOnlyDictionary<string, int> deleted)
    {
        if (IsClosed) return;
        foreach (var (key, revision) in deleted)
            if (MarksState.Tombstones.GetValueOrDefault(key, -1) < revision) MarksState.Tombstones[key] = revision;
        if (MarksState.Tombstones.Count > GroupLimits.SyncTombstones * 2)
            MarksState.Tombstones = MarksState.Tombstones.OrderByDescending(kv => kv.Value).Take(GroupLimits.SyncTombstones).ToDictionary(kv => kv.Key, kv => kv.Value);
    }

    // [groups] What the round engine needs (HermesKit/Groups/GroupStore.swift: room(uid:), key(_:), setRuntime,
    // endAllRounds, refreshDescriptors).

    public GroupRoom? Room(Guid uid) => rooms.FirstOrDefault(r => r.Uid == uid);
    public string? Key(Guid uid) => Room(uid)?.Key;

    /// A runtime-only change (epoch, running, the turn): never synced, told only when something changed.
    public void SetRuntime(string key, Action<GroupRoom> mutate)
    {
        if (IsClosed) return;
        var index = rooms.FindIndex(r => r.Key == key);
        if (index < 0) return;
        var room = rooms[index].Clone();
        mutate(room);
        if (room.Same(rooms[index])) return;
        rooms[index] = room;
        Notify();
    }

    /// The account is leaving: every room's round ends (its epoch moves on, so a waiting turn sees it is not current).
    public void EndAllRounds()
    {
        for (var i = 0; i < rooms.Count; i++)
        {
            var room = rooms[i].Clone();
            room.Epoch += 1;
            room.Running = false;
            room.Turn = null;
            rooms[i] = room;
        }
    }

    /// The room's saved descriptors from the roster's bots that name it, in roster order (members on another gateway
    /// kept). Nothing before the roster has loaded.
    public void RefreshDescriptors(string key, bool bump = false)
    {
        if (Room(key) is not { IsHosted: false } room || Roster is not { Loaded: true } roster) return;
        var names = roster.Profiles.Where(p => GroupKeys.Groups(p.Meta).Contains(room.Name)).Select(p => p.Name).ToList();
        var old = new Dictionary<string, GroupMember>();
        foreach (var m in room.Members) old.TryAdd(m.Name, m);
        var local = roster.Profiles.Select(p => p.Name).Where(names.Contains).Select(name =>
        {
            var member = old.GetValueOrDefault(name) is { SourceScoped: false } kept ? kept.Clone() : new GroupMember(name);
            member.Handle = GroupMentions.Handle(name, member.Handle);
            return member;
        });
        var next = local.Concat(room.Members.Where(m => m.SourceScoped).Select(m => m.Clone())).ToList();
        if (next.Count == room.Members.Count && next.Zip(room.Members).All(p => p.First.Same(p.Second)) && !bump) return;
        Update(key, r =>
        {
            r.Members = next;
            if (bump) r.SyncRevision += 1;
        }, sync: bump || room.Log.Count > 0);
    }

    // [groups] What a room's management needs (GroupManager; HermesKit/Groups/GroupStore.swift create / rename / delete).

    /// A room New Group Chat made once its bots' writes landed: a deleted name is live again, an id-less room of that
    /// name gives way. Not the mirror yet: it carries rooms with a log (GroupSnapshot.Local), so the first send does.
    public void AddCreated(GroupRoom room)
    {
        if (IsClosed) return;
        MarksState.DeletedNames.Remove(room.Name);
        SettleOwed(room.Name);
        rooms.RemoveAll(r => r.Name == room.Name && r.RoomId == null);
        rooms.Add(room.Clone());
        Notify();
    }

    public void SetTombstone(string key, int revision)
    {
        if (IsClosed) return;
        MarksState.Tombstones[key] = revision;
    }

    /// Delete Group Chat's first step: the tombstone, the deleted name (and the bots' writes still owed), the room and
    /// its marks gone at once.
    public void RemoveDeleted(string key, int tombstone, bool owesWrites)
    {
        if (IsClosed || Room(key) is not { } room) return;
        MarksState.Tombstones[key] = tombstone;
        if (!MarksState.DeletedNames.Contains(room.Name)) MarksState.DeletedNames.Add(room.Name);
        if (owesWrites && MarksState.OwedDeletes?.Contains(room.Name) != true) MarksState.OwedDeletes = [.. MarksState.OwedDeletes ?? [], room.Name];
        rooms.RemoveAll(r => r.Key == key);
        MoveMarks(key, null);
        activity.Remove(key);
        Notify();
        OnRoomRemoved?.Invoke(room);
    }

    /// The bots' writes of a deleted name are done.
    public void SettleOwed(string name)
    {
        if (MarksState.OwedDeletes is not { } owed || !owed.Remove(name)) return;
        if (owed.Count == 0) MarksState.OwedDeletes = null;
    }

    /// Adds a room this device made (Create Group Chat), its name made unique.
    public GroupRoom Add(string name, IEnumerable<GroupMember> members, string? roomId = null)
    {
        var room = new GroupRoom(GroupKeys.UniqueName(name, RoomNames), roomId ?? GroupKeys.NewRoomId()) { Members = [.. members.Select(m => m.Clone())] };
        rooms.Add(room);
        Notify();
        return room.Clone();
    }
}
