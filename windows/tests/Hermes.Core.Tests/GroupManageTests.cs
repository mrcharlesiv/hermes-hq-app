using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// A room's management (GroupManager, GroupManageWords): App/Groups/GroupActions.swift, AddToGroupController.swift,
/// GroupBotsPicker.swift, GroupInfoSheet.swift and HermesKit/Groups/GroupStore.swift's membership writes.
public class GroupManageTests
{
    /// The bots' `hermes-bots` metas in memory; `failOn` refuses one profile's writes.
    private sealed class FakeWriter(params string[] profiles) : IGroupMetaWriter
    {
        public readonly Dictionary<string, JsonObject> Metas = profiles.ToDictionary(p => p, _ => new JsonObject());
        public readonly List<string> Writes = [];
        public string? FailOn;
        public IReadOnlyList<string> ProfileNames => [.. Metas.Keys];
        public JsonObject CurrentMeta(string profile) => (JsonObject)Metas[profile].DeepClone();
        public Task WriteAsync(string profile, string failureTitle, Func<JsonObject, JsonObject?> patch)
        {
            if (profile == FailOn) throw new BotWriteException(failureTitle, BotWriteException.NotSavedReason);
            if (patch(CurrentMeta(profile)) is not { } p) return Task.CompletedTask;
            foreach (var (k, v) in p) Metas[profile][k] = v?.DeepClone();
            Writes.Add(profile);
            return Task.CompletedTask;
        }
        public List<string> Groups(string p) => GroupKeys.Groups(Metas[p]);
    }

    private sealed class Roster(FakeWriter w) : IGroupRoster
    {
        public bool Loaded => true;
        public IReadOnlyList<GroupRosterProfile> Profiles => [.. w.ProfileNames.Select(p => new GroupRosterProfile(p) { Meta = w.CurrentMeta(p), BotName = p.ToUpperInvariant()[..1] + p[1..] })];
    }

    private static (GroupManager, GroupStore, FakeWriter, List<string>) Make(params GroupRoom[] rooms)
    {
        var w = new FakeWriter("ivy", "juno", "otto", "wren");
        var store = new GroupStore(rooms) { };
        store.Roster = new Roster(w);
        var mirrored = new List<string>();
        store.OnMirrorChange = mirrored.Add;
        return (new GroupManager(store, w), store, w, mirrored);
    }

    [Fact]
    public async Task CreateWritesEachBotsGroupsInRosterOrderAndAddsTheRoom()
    {
        var (m, store, w, mirrored) = Make();
        var key = await m.CreateAsync("  Desk  ", ["otto", "ivy"]);
        Assert.Equal(["ivy", "otto"], w.Writes);
        Assert.Equal(["Desk"], w.Groups("ivy"));
        Assert.Equal("Desk", w.Metas["otto"]["group"]!.GetValue<string>());
        var room = store.Room(key)!;
        Assert.StartsWith("id:r", key, StringComparison.Ordinal);
        Assert.Equal(["ivy", "otto"], room.Members.Select(x => x.Name));
        Assert.Empty(mirrored);   // an empty room reaches the mirror with its first send
        // A taken name is made unique.
        var second = await m.CreateAsync("Desk", ["ivy", "juno"]);
        Assert.Equal("Desk 2", store.Room(second)!.Name);
    }

    [Fact]
    public async Task ACreateThatFailsUndoesTheWritesMadeAndSaysCouldntCreate()
    {
        var (m, store, w, _) = Make();
        w.FailOn = "otto";
        var e = await Assert.ThrowsAsync<BotWriteException>(() => m.CreateAsync("Desk", ["ivy", "otto"]));
        Assert.Equal("Couldn’t Create Desk", e.Title);
        Assert.Empty(w.Groups("ivy"));
        Assert.Empty(store.Rooms);
    }

    [Fact]
    public async Task RenameRewritesTheSeatedBotsAndRefusesATakenName()
    {
        var (m, store, w, mirrored) = Make();
        var key = await m.CreateAsync("Desk", ["ivy", "juno"]);
        await m.CreateAsync("Plans", ["ivy", "wren"]);
        var taken = await Assert.ThrowsAsync<GroupNameTakenException>(() => m.RenameAsync(key, "Plans"));
        Assert.Equal("A group named “Plans” already exists.", taken.Message);
        Assert.Equal("A group named “Plans” already exists.", m.NameProblem(key, " Plans "));
        Assert.Null(m.NameProblem(key, "Desk"));
        Assert.Null(m.NameProblem(key, "Front Desk"));
        mirrored.Clear();
        await m.RenameAsync(key, "Front Desk");
        Assert.Equal(["Front Desk", "Plans"], w.Groups("ivy"));
        Assert.Equal(["Front Desk"], w.Groups("juno"));
        Assert.Equal("Front Desk", store.Room(key)!.Name);   // an id'd room keeps its key
        Assert.Equal([key], mirrored);
    }

    [Fact]
    public async Task SetMembersAddsAndRemovesAndSetMembershipBumpsTheRoom()
    {
        var (m, store, w, _) = Make();
        var key = await m.CreateAsync("Desk", ["ivy", "juno"]);
        await m.SetMembersAsync(key, ["ivy", "otto", "wren"]);
        Assert.Empty(w.Groups("juno"));
        Assert.Equal(["Desk"], w.Groups("wren"));
        Assert.Equal(["ivy", "otto", "wren"], store.Room(key)!.Members.Select(x => x.Name));
        var rev = store.Room(key)!.SyncRevision;
        await m.SetMembershipAsync("juno", key, true, "Juno");
        Assert.Equal(["ivy", "juno", "otto", "wren"], store.Room(key)!.Members.Select(x => x.Name));
        Assert.Equal(rev + 1, store.Room(key)!.SyncRevision);
        w.FailOn = "juno";
        var e = await Assert.ThrowsAsync<BotWriteException>(() => m.SetMembershipAsync("juno", key, false, "Juno"));
        Assert.Equal("Couldn’t Change Juno’s Group Chats", e.Title);
    }

    [Fact]
    public async Task CreateSoloRefusesATakenOrEmptyName()
    {
        var (m, store, w, _) = Make();
        await m.CreateAsync("Desk", ["ivy", "juno"]);
        await Assert.ThrowsAsync<GroupNameTakenException>(() => m.CreateSoloAsync("Desk", "otto", "Otto"));
        var key = await m.CreateSoloAsync(" Solo ", "otto", "Otto");
        Assert.Equal(["Solo"], w.Groups("otto"));
        Assert.Equal(["otto"], store.Room(key)!.Members.Select(x => x.Name));
    }

    [Fact]
    public async Task DeleteDropsTheRoomAndItsMarksFirstThenClearsTheBots()
    {
        var (m, store, w, _) = Make();
        var key = await m.CreateAsync("Desk", ["ivy", "juno"]);
        store.SetUnread(key, true);
        var removed = new List<string>();
        store.OnRoomRemoved = r => removed.Add(r.Name);
        w.FailOn = "juno";
        var e = await Assert.ThrowsAsync<BotWriteException>(() => m.DeleteAsync(key));
        Assert.Equal("Couldn’t Delete Desk", e.Title);
        Assert.Null(store.Room(key));                       // gone here, and stays gone
        Assert.False(store.IsUnread(key));
        Assert.Equal(["Desk"], removed);
        Assert.True(store.Tombstones.ContainsKey(key));
        Assert.Equal(["Desk"], store.MarksState.OwedDeletes!);
        Assert.Contains("Desk", store.MarksState.DeletedNames);
        w.FailOn = null;
        await m.FinishDeleteAsync("Desk");                  // the retry
        Assert.Empty(w.Groups("ivy"));
        Assert.Empty(w.Groups("juno"));
        Assert.Null(store.MarksState.OwedDeletes);
    }

    [Fact]
    public void TheRowMenuHasTheMacsItemsInOrder()
    {
        var row = new GroupRowModel("id:r1", "Desk", "2 bots", GroupRowWords.Tone.Secondary);
        Assert.Equal(["Group Info", "Pin", "Mute", "Mark as Unread", "Hide", "Delete Group Chat"], GroupRowMenu.Items(row, true).Select(i => i.Title));
        var mute = GroupRowMenu.Items(row, true).Single(i => i.Id == "mute");
        Assert.Equal(["For 1 Hour", "For 8 Hours", "For 1 Week", "Always"], mute.Durations.Select(BotMutes.Title));
        var other = row with { Pinned = true, Muted = true, Unread = true, Hidden = true };
        Assert.Equal(["Group Info", "Unpin", "Unmute", "Mark as Read", "Show in Bots", "Delete Group Chat"], GroupRowMenu.Items(other, true).Select(i => i.Title));
        Assert.Equal(["Group Info", "Mute", "Mark as Unread", "Show in Bots", "Delete Group Chat"], GroupRowMenu.Items(row with { Hidden = true }, true).Select(i => i.Title));
        var delete = GroupRowMenu.Items(row, false)[^1];
        Assert.True(delete.Destructive);
        Assert.False(delete.Enabled);
        Assert.Equal("Your gateway is offline", delete.Subtitle);
        Assert.Equal("Delete “Desk”?", GroupManageWords.DeleteTitle("Desk"));
        Assert.Equal("The group chat and its messages are removed. The bots and their own chats are kept. This can’t be undone.", GroupManageWords.DeleteMessage);
        Assert.Equal("Your gateway is offline", GroupManageWords.NewGroupDisabledReason(5, false));
        Assert.Equal("Needs at least 2 bots", GroupManageWords.NewGroupDisabledReason(1, true));
        Assert.Null(GroupManageWords.NewGroupDisabledReason(2, true));
    }

    [Fact]
    public void JoinAndPickRulesFollowTheMac()
    {
        Assert.Equal("Full (6 bots)", GroupJoinRules.Subtitle(false, 6));
        Assert.Equal("Needs at least 2 bots", GroupJoinRules.Subtitle(true, 2));
        Assert.Equal("3 bots", GroupJoinRules.Subtitle(true, 3));
        Assert.True(GroupJoinRules.CanRemoveAll([3, 4]));
        Assert.False(GroupJoinRules.CanRemoveAll([3, 2]));
        Assert.False(GroupJoinRules.CanRemoveAll([]));
        Assert.Equal("Ivy isn’t in any group chats yet. Name one below to create it.", GroupJoinRules.EmptyLine("Ivy", false));
        Assert.Equal("Ivy · Groups", GroupJoinRules.Title("Ivy"));

        Assert.Equal(("ivy", GroupPickRules.Tap.Added), Unpack(GroupPickRules.Toggle("ivy", [], false)));
        Assert.Equal(("ivy,juno", GroupPickRules.Tap.Locked), Unpack(GroupPickRules.Toggle("ivy", ["ivy", "juno"], true)));
        Assert.Equal(("juno", GroupPickRules.Tap.Removed), Unpack(GroupPickRules.Toggle("ivy", ["ivy", "juno"], false)));
        Assert.Equal(GroupPickRules.Tap.Full, GroupPickRules.Toggle("x", ["a", "b", "c", "d", "e", "f"], false).Result);
        Assert.False(GroupPickRules.CanCreate(1));
        Assert.True(GroupPickRules.CanCreate(6));
        Assert.False(GroupPickRules.CanCreate(7));
        Assert.Equal("Ivy, Juno", GroupPickRules.Placeholder(["Ivy", "Juno"]));
        Assert.Equal("Group name", GroupPickRules.Placeholder([]));
        Assert.Equal("Pick 2–6 bots to talk together.", GroupPickRules.Line(null));
        Assert.Equal("Pick 2–6 bots for “Desk”. The group chat and its history stay as they are.", GroupPickRules.Line("Desk"));
        Assert.Equal("No bots match “zz”.", GroupPickRules.None(" zz "));
        Assert.True(GroupPickRules.Matches("Ivy", "ivy", "Research", "sear"));
        Assert.Equal(GroupPickRules.LimitFooter, GroupPickRules.Footer(6, false));
        Assert.Equal(GroupPickRules.FloorFooter, GroupPickRules.Footer(2, true));
        Assert.Null(GroupPickRules.Footer(3, true));

        var seat = new GroupSeat("ivy", "ivy", "Ivy", "ivy", new GroupMember("ivy"));
        Assert.Equal("On another gateway", GroupInfoWords.MemberLine(seat with { Remote = true }, null, null));
        Assert.Equal("On Studio", GroupInfoWords.MemberLine(seat with { Remote = true, RemoteLabel = "Studio" }, null, null));
        Assert.Equal("Can’t reach this bot", GroupInfoWords.MemberLine(seat with { Missing = true }, null, "Research"));
        Assert.Equal("Research", GroupInfoWords.MemberLine(seat, null, "Research"));
        Assert.Equal("Add Bots", GroupInfoWords.EditBots(GroupInfoWords.IsFloor(2)));
        Assert.Equal("Edit Bots", GroupInfoWords.EditBots(GroupInfoWords.IsFloor(3)));
    }

    [Fact]
    public void TheGroupManageWalksChecksPassTheMacsSurfacesAndNameWhatIsWrong()
    {
        var row = new GroupRowModel(GroupManageWalkProof.LaunchKey, "Launch Room", "2 bots", GroupRowWords.Tone.Secondary);
        var items = GroupRowMenu.Items(row, true).Select(i => (i.Title, i.Enabled)).ToList();
        Assert.Null(GroupManageWalkProof.RowMenu(items));
        Assert.Equal("Delete Group Chat is disabled", GroupManageWalkProof.RowMenu([.. GroupRowMenu.Items(row, false).Select(i => (i.Title, i.Enabled))]));
        Assert.StartsWith("the room's menu reads Group Info · Unpin", GroupManageWalkProof.RowMenu([.. GroupRowMenu.Items(row with { Pinned = true }, true).Select(i => (i.Title, i.Enabled))]));

        Assert.Null(GroupManageWalkProof.Info("Group Info", "Launch Room", "2 bots", ["ivy", "research"]));
        Assert.Equal("the members are research, ivy", GroupManageWalkProof.Info("Group Info", "Launch Room", "2 bots", ["research", "ivy"]));
        Assert.Equal("the sheet has no line under the name", GroupManageWalkProof.Info("Group Info", "Launch Room", "", ["ivy", "research"]));

        var line = GroupPickRules.Line("Launch Room");
        (string, bool, bool)[] bots = [("ivy", true, false), ("research", true, false), ("notes", false, true)];
        Assert.Null(GroupManageWalkProof.Picker("Launch Room", line, bots, GroupPickRules.FloorFooter));
        Assert.Equal("a pick can be taken away at 2 bots", GroupManageWalkProof.Picker("Launch Room", line, [("ivy", true, true), ("research", true, false)], GroupPickRules.FloorFooter));
        Assert.Equal("the picker's footer reads ", GroupManageWalkProof.Picker("Launch Room", line, bots, ""));
    }

    private static (string, GroupPickRules.Tap) Unpack((List<string> Picked, GroupPickRules.Tap Result) t) => (string.Join(",", t.Picked), t.Result);
}
