using System.Text.Json.Nodes;
using Hermes.Core.Bots;

namespace Hermes.Core.Groups;

// [groups] A room's management: New Group Chat, Name & Photo's rename, Edit Bots, Add to Group Chat…'s switches and
// Create and Join, and Delete Group Chat (HermesKit/Groups/GroupStore.swift §4.3 "Membership writes"; docs/spec/
// 3x-groups.md §7.1, §7.2, §7.5, §7.7). Membership is each bot's `ui_meta["hermes-bots"].groups` (BotStore's meta
// write); the room itself reaches the default profile's mirror through GroupSync's compare-and-swap.

/// The bots' side of a membership write (the Mac's `bots.writeBotMeta` / `bots.currentMeta`).
public interface IGroupMetaWriter
{
    /// The roster's profile names, in roster order.
    IReadOnlyList<string> ProfileNames { get; }
    JsonObject CurrentMeta(string profile);
    /// Patches `hermes-bots` with what `patch` returns (null: nothing to write); throws a BotWriteException titled so.
    Task WriteAsync(string profile, string failureTitle, Func<JsonObject, JsonObject?> patch);
}

/// The app's writer: BotStore's meta write path (show now, read, merge, write, put back on refusal).
public sealed class BotStoreGroupWriter(BotStore bots) : IGroupMetaWriter
{
    public IReadOnlyList<string> ProfileNames => [.. bots.Rows.Select(r => r.Id)];
    public JsonObject CurrentMeta(string profile) => bots.CurrentMeta(profile);
    public Task WriteAsync(string profile, string failureTitle, Func<JsonObject, JsonObject?> patch) =>
        bots.WriteMetaAsync(profile, failureTitle, patch);
}

public sealed class GroupManager(GroupStore store, IGroupMetaWriter writer, GroupSync? sync = null)
{
    public GroupStore Store { get; } = store;

    private Task Write(string profile, string title, Func<JsonObject, List<string>?> change) =>
        writer.WriteAsync(profile, title, meta => change(meta) is { } groups ? GroupKeys.Patch(groups) : null);

    private static BotWriteException Failure(Exception e, string title) => e switch
    {
        BotWriteException known => new BotWriteException(title, known.Reason, known.Detail),
        _ => new BotWriteException(title, BotWriteException.ReasonOf(e), e.Message),
    };

    private List<string> ProfilesNaming(string name) =>
        [.. writer.ProfileNames.Where(p => GroupKeys.Groups(writer.CurrentMeta(p)).Contains(name))];

    private HashSet<string> TakenNames()
    {
        var taken = Store.RoomNames.ToHashSet();
        foreach (var p in writer.ProfileNames) taken.UnionWith(GroupKeys.Groups(writer.CurrentMeta(p)));
        return taken;
    }

    private List<GroupMember> Descriptors(IReadOnlyCollection<string> names, IReadOnlyList<GroupMember> saved)
    {
        var old = new Dictionary<string, GroupMember>();
        foreach (var m in saved) old.TryAdd(m.Name, m);
        var local = writer.ProfileNames.Where(names.Contains).Select(name =>
        {
            var member = old.GetValueOrDefault(name) is { SourceScoped: false } kept ? kept.Clone() : new GroupMember(name);
            member.Handle = GroupMentions.Handle(name, member.Handle);
            return member;
        });
        return [.. local, .. saved.Where(m => m.SourceScoped).Select(m => m.Clone())];
    }

    /// New Group Chat (§7.5): the name made unique, a new room id, `groups` written on each bot in roster order. A
    /// failed write undoes the ones already made and throws `Couldn’t Create <name>`. Returns the room's key.
    public async Task<string> CreateAsync(string raw, IReadOnlyCollection<string> members, string? image = null)
    {
        var name = GroupKeys.UniqueName(raw, TakenNames());
        var title = GroupManageWords.CouldNotCreate(name);
        var ordered = writer.ProfileNames.Where(members.Contains).ToList();
        var done = new List<string>();
        try
        {
            foreach (var profile in ordered)
            {
                await Write(profile, title, m => GroupKeys.MembershipAdding(m, name));
                done.Add(profile);
            }
        }
        catch (Exception e)
        {
            foreach (var profile in done)
                try { await Write(profile, title, m => GroupKeys.MembershipRemoving(m, name)); } catch (Exception) { }
            throw Failure(e, title);
        }
        var room = new GroupRoom(name, GroupKeys.NewRoomId()) { Members = Descriptors(ordered, []), Image = image };
        Store.AddCreated(room);
        return room.Key;
    }

    /// Name & Photo's problem line for a name typed for `key` (null: the name can be saved, or is unchanged).
    public string? NameProblem(string key, string raw)
    {
        var name = GroupKeys.CleanName(raw);
        if (name.Length == 0 || Store.Room(key)?.Name == name) return null;
        return TakenNames().Contains(name) ? new GroupNameTakenException(name).Message : null;
    }

    /// Rename (§7.2): the name rewritten in every seated bot's `groups`, the room re-keyed only when it had no id.
    public async Task RenameAsync(string key, string raw)
    {
        if (Store.Room(key) is not { } room) return;
        var name = GroupKeys.CleanName(raw);
        if (name.Length == 0 || name == room.Name) return;
        if (TakenNames().Contains(name)) throw new GroupNameTakenException(name);
        var title = GroupManageWords.CouldNotRename(room.Name);
        var old = room.Name;
        var done = new List<string>();
        try
        {
            foreach (var profile in ProfilesNaming(old))
            {
                await Write(profile, title, m => GroupKeys.MembershipRenaming(m, old, name));
                done.Add(profile);
            }
        }
        catch (Exception e)
        {
            foreach (var profile in done)
                try { await Write(profile, title, m => GroupKeys.MembershipRenaming(m, name, old)); } catch (Exception) { }
            throw Failure(e, title);
        }
        var hadId = room.RoomId != null;
        Store.Update(key, r =>
        {
            r.Name = name;
            r.RoomId ??= GroupKeys.NewRoomId();
            r.SyncRevision += 1;
        });
        if (!hadId)
        {
            Store.SetTombstone(key, (sync?.RemoteRevision ?? 0) + 1);
            sync?.Schedule(deleted: key);
        }
    }

    /// Name & Photo's Save (GroupNamePhotoController.save): the rename first (a taken name throws before the photo is
    /// touched), then the photo on the room's key after it, which a room with no id changes. A null image is Remove Photo.
    public async Task SaveNameAndPhotoAsync(string key, string? name, bool imageChanged, string? image)
    {
        if (Store.Room(key) is not { } room) return;
        var uid = room.Uid;
        if (name != null) await RenameAsync(key, name);
        if (imageChanged && Store.Rooms.FirstOrDefault(r => r.Uid == uid) is { } now) Store.SetImage(now.Key, image);
    }

    /// Edit Bots (§7.5 edit mode): the `groups` change of each bot added or removed, then the descriptors.
    public async Task SetMembersAsync(string key, IReadOnlyCollection<string> names)
    {
        if (Store.Room(key) is not { } room) return;
        if (room.IsHosted) throw HostedMembersFixed(room.Name);
        var title = GroupManageWords.CouldNotChangeBots(room.Name);
        var current = ProfilesNaming(room.Name).ToHashSet();
        var roomName = room.Name;
        try
        {
            foreach (var profile in writer.ProfileNames)
            {
                if (names.Contains(profile) && !current.Contains(profile))
                    await Write(profile, title, m => GroupKeys.MembershipAdding(m, roomName));
                else if (!names.Contains(profile) && current.Contains(profile))
                    await Write(profile, title, m => GroupKeys.MembershipRemoving(m, roomName));
            }
        }
        catch (Exception e)
        {
            Store.RefreshDescriptors(key);
            throw Failure(e, title);
        }
        Store.Update(key, r =>
        {
            r.Members = Descriptors(names, r.Members);
            r.SyncRevision += 1;
        });
    }

    /// One bot joins or leaves one room (Add to Group Chat…, §7.7).
    public async Task SetMembershipAsync(string profile, string key, bool member, string botName)
    {
        if (Store.Room(key) is not { } room) return;
        if (room.IsHosted) throw HostedMembersFixed(room.Name);
        var title = GroupManageWords.CouldNotChangeGroupChats(botName);
        var roomName = room.Name;
        try
        {
            await Write(profile, title, m => member ? GroupKeys.MembershipAdding(m, roomName) : GroupKeys.MembershipRemoving(m, roomName));
        }
        catch (Exception e) { throw Failure(e, title); }
        Store.RefreshDescriptors(key, bump: true);
    }

    /// Create and Join (§7.7): a room named so with this bot alone.
    public async Task<string> CreateSoloAsync(string raw, string profile, string botName)
    {
        var name = GroupKeys.CleanName(raw);
        if (name.Length == 0 || TakenNames().Contains(name)) throw new GroupNameTakenException(name);
        try { return await CreateAsync(name, [profile]); }
        catch (Exception e) { throw Failure(e, GroupManageWords.CouldNotChangeGroupChats(botName)); }
    }

    /// Delete Group Chat (§7.1): the tombstone first, the room and its marks gone at once, then the gateway writes.
    /// Throws `Couldn’t Delete <name>` when a write failed; the room stays gone and FinishDeleteAsync retries them.
    public async Task DeleteAsync(string key)
    {
        if (Store.Room(key) is not { } room) return;
        var owed = ProfilesNaming(room.Name).Count > 0;
        Store.RemoveDeleted(key, Math.Max(room.SyncRevision, (sync?.RemoteRevision ?? 0) + 1), owed);
        sync?.Schedule(deleted: key);
        await FinishDeleteAsync(room.Name);
    }

    public async Task FinishDeleteAsync(string name)
    {
        var title = GroupManageWords.CouldNotDelete(name);
        Exception? first = null;
        foreach (var profile in ProfilesNaming(name))
        {
            try { await Write(profile, title, m => GroupKeys.MembershipRemoving(m, name)); }
            catch (Exception e) { first ??= e; }
        }
        if (first != null) throw Failure(first, title);
        if (!Store.IsClosed) Store.SettleOwed(name);
    }

    /// [hosted] A room Hermes runs keeps the bots it was made with.
    public static BotWriteException HostedMembersFixed(string name) =>
        new(GroupManageWords.CouldNotChangeBots(name),
            "This group chat runs in Hermes, which keeps the bots it was made with. Make a new group chat for other bots.");
}
