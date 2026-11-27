using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Net;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// A room's management against a real wire (GroupManager → BotStore's `profiles.configure` of each bot's
/// `hermes-bots.groups`, and GroupSync's compare-and-swap on the default profile's mirror): New Group Chat, Rename,
/// Edit Bots (add and remove) and Delete Group Chat, as the Mac's GroupStore makes them. Its own `--group-rooms`
/// settings stand-in (HQW_E2E_GROUPMANAGE_CREDENTIALS, port 9832), so the read-only room tests on 9831 keep their seed;
/// without it this passes vacuously.
[Trait("Category", "E2E")]
public class GroupManageEndToEndTests
{
    private static async Task<JsonNode> State(string url)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + "/__settings/state"))!;
    }

    private static List<string> Groups(JsonNode state, string profile) =>
        GroupKeys.Groups(state.Obj("profiles").Obj(profile).Obj("ui_meta").Obj("hermes-bots") as JsonObject);

    private static GroupMirror Mirror(JsonNode state) =>
        GroupSnapshot.Parse(state.Obj("profiles").Obj("default").Obj("ui_meta").Get(GroupSnapshot.MetaKey)?.DeepClone());

    /// The group-manage walk's checks against what the app reads from the read-only room stand-in (9831): Launch Room's
    /// row menu, Group Info's members, the picker's picks in edit mode.
    [Fact]
    public async Task TheGroupManageWalkSeesTheMacsSurfacesOnTheStandInsLaunchRoom()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_GROUPS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(cred.Str("url")!), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);
        var gw = new ClientGateway(client);
        var bots = new BotStore(gw, new MemoryDeviceStore());
        await bots.RefreshAsync();
        var store = new GroupStore { Roster = new BotStoreGroupRoster(bots) };
        var sync = new GroupSync(store, gw) { Debounce = TimeSpan.FromSeconds(60) };
        sync.Pulled(bots.DefaultProfileRow());
        try
        {
            var row = store.Rows().Single(r => r.Id == GroupManageWalkProof.LaunchKey);
            Assert.Null(GroupManageWalkProof.RowMenu([.. GroupRowMenu.Items(row, true).Select(i => (i.Title, i.Enabled))]));
            var seats = store.Seated(store.Room(GroupManageWalkProof.LaunchKey)!);
            Assert.Null(GroupManageWalkProof.Info(GroupInfoWords.Title, row.Name, GroupInfoWords.Subtitle(row, seats.Count), [.. seats.Select(s => s.Name)]));
            var picked = seats.Select(s => s.Name).ToList();
            var shown = bots.Rows.Where(r => !r.Hidden).Select(r => (r.Id, picked.Contains(r.Id), !(picked.Contains(r.Id) && picked.Count <= GroupLimits.MinMembers))).ToList();
            Assert.Null(GroupManageWalkProof.Picker(row.Name, GroupPickRules.Line(row.Name), shown, GroupPickRules.Footer(picked.Count, editing: true)));
            Assert.False(sync.HasPending);
        }
        finally { sync.Shutdown(); }
    }

    /// [WIN-51] Name & Photo's photo: set on Launch Room, it reaches the default profile's mirror (the store the Mac's
    /// `setImage` publishes to; settings-gateway.py takes it as any ui_meta write) and a second device's rows; Remove
    /// Photo takes it out of both. The photo is a synthetic data URL under the mirror's 24,000 characters.
    [Fact]
    public async Task SettingAndClearingTheGroupPhotoReachesTheMirrorAndAnotherDevice()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_GROUPMANAGE_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        using (var http = new HttpClient())
            (await http.PostAsync(url.TrimEnd('/') + "/__settings/reset", new StringContent("{}"))).EnsureSuccessStatusCode();
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);

        var gw = new ClientGateway(client);
        var bots = new BotStore(gw, new MemoryDeviceStore());
        await bots.RefreshAsync();
        var store = new GroupStore { Roster = new BotStoreGroupRoster(bots) };
        var sync = new GroupSync(store, gw) { Debounce = TimeSpan.FromSeconds(60) };
        sync.Pulled(bots.DefaultProfileRow());
        var manager = new GroupManager(store, new BotStoreGroupWriter(bots), sync);
        const string key = GroupManageWalkProof.LaunchKey;
        // A synthetic JPEG's opening bytes, not a real photo.
        var photo = GroupPhoto.Prefix + Convert.ToBase64String([.. new byte[] { 0xFF, 0xD8, 0xFF, 0xE0 }, .. Enumerable.Range(0, 600).Select(i => (byte)i), 0xFF, 0xD9]);
        try
        {
            Assert.Null(Mirror(await State(url)).Rooms[key].Image);
            var draft = new GroupNamePhotoDraft(store.Room(key)!.Name, store.Room(key)!.Image) { Image = photo };
            Assert.True(draft.CanSave);
            await manager.SaveNameAndPhotoAsync(key, draft.NameChanged ? draft.CleanName : null, draft.ImageChanged, draft.Image);
            Assert.Equal(photo, store.Rows().Single(r => r.Id == key).Image);
            await sync.FlushNow();
            var state = await State(url);
            Assert.Equal(photo, Mirror(state).Rooms[key].Image);
            Assert.Equal("Launch Room", Mirror(state).Rooms[key].Name);
            Assert.Equal(["Launch Room", "Weekend Plans"], Groups(state, "ivy"));   // the bots' groups are not touched

            // Another device pulls the mirror and draws the photo in its row.
            var otherBots = new BotStore(gw, new MemoryDeviceStore());
            await otherBots.RefreshAsync();
            var other = new GroupStore { Roster = new BotStoreGroupRoster(otherBots) };
            var otherSync = new GroupSync(other, gw) { Debounce = TimeSpan.FromSeconds(60) };
            try
            {
                otherSync.Pulled(otherBots.DefaultProfileRow());
                Assert.Equal(photo, other.Rows().Single(r => r.Id == key).Image);
            }
            finally { otherSync.Shutdown(); }

            // Remove Photo.
            var clearing = new GroupNamePhotoDraft(store.Room(key)!.Name, store.Room(key)!.Image);
            Assert.True(clearing.ShowsRemove);
            clearing.Image = null;
            await manager.SaveNameAndPhotoAsync(key, null, clearing.ImageChanged, clearing.Image);
            await sync.FlushNow();
            state = await State(url);
            Assert.Null(Mirror(state).Rooms[key].Image);
            Assert.Null(store.Room(key)!.Image);
            Assert.False(sync.HasPending);
        }
        finally
        {
            sync.Shutdown();
            using var http = new HttpClient();
            await http.PostAsync(url.TrimEnd('/') + "/__settings/reset", new StringContent("{}"));
        }
    }

    [Fact]
    public async Task CreateRenameAddRemoveAndDeleteReachTheBotsAndTheMirror()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_GROUPMANAGE_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        using (var http = new HttpClient())
            (await http.PostAsync(url.TrimEnd('/') + "/__settings/reset", new StringContent("{}"))).EnsureSuccessStatusCode();
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);

        var gw = new ClientGateway(client);
        var bots = new BotStore(gw, new MemoryDeviceStore());
        await bots.RefreshAsync();
        var store = new GroupStore { Roster = new BotStoreGroupRoster(bots) };
        var sync = new GroupSync(store, gw) { Debounce = TimeSpan.FromSeconds(60) };
        sync.Pulled(bots.DefaultProfileRow());
        var manager = new GroupManager(store, new BotStoreGroupWriter(bots), sync);
        try
        {
            Assert.Equal(["Launch Room", "Weekend Plans"], store.Rooms.Select(r => r.Name).Order(StringComparer.Ordinal));

            // 1. New Group Chat: Notes and Research name it; the mirror carries it after the publish.
            var key = await manager.CreateAsync("Desk Room", ["research", "notes"]);
            await sync.FlushNow();
            Assert.False(sync.HasPending);   // an empty room is not in the mirror: its first send puts it there
            Assert.False(GroupSnapshot.Parse((await State(url)).Obj("profiles").Obj("default").Obj("ui_meta").Get(GroupSnapshot.MetaKey)?.DeepClone()).Rooms.ContainsKey(key));
            store.Append(new GroupMessage(null, 1_790_000_000_000, GroupAuthor.You, "Who has the desk today?", "tfixture-desk"), key);
            await sync.FlushNow();
            var state = await State(url);
            Assert.Equal(["Weekend Plans", "Desk Room"], Groups(state, "notes"));
            Assert.Equal(["Launch Room", "Desk Room"], Groups(state, "research"));
            Assert.Equal("Desk Room", Mirror(state).Rooms[key].Name);

            // 2. Rename: every seated bot's groups, and the mirror's name, follow; the key is kept.
            await manager.RenameAsync(key, "Front Desk");
            await sync.FlushNow();
            state = await State(url);
            Assert.Equal(["Weekend Plans", "Front Desk"], Groups(state, "notes"));
            Assert.Equal(["Launch Room", "Front Desk"], Groups(state, "research"));
            Assert.Equal("Front Desk", Mirror(state).Rooms[key].Name);
            await Assert.ThrowsAsync<GroupNameTakenException>(() => manager.RenameAsync(key, "Weekend Plans"));

            // 3. Add a member (Add to Group Chat…'s switch), then remove one (Edit Bots).
            await manager.SetMembershipAsync("ivy", key, true, "Ivy");
            await sync.FlushNow();
            state = await State(url);
            Assert.Equal(["Launch Room", "Weekend Plans", "Front Desk"], Groups(state, "ivy"));
            Assert.Equal(["ivy", "research", "notes"], store.Seated(store.Room(key)!).Select(s => s.Name).OrderBy(n => n != "ivy").ThenBy(n => n != "research"));
            Assert.Equal(3, Mirror(state).Rooms[key].Members.Count);
            await manager.SetMembersAsync(key, ["ivy", "notes"]);
            await sync.FlushNow();
            state = await State(url);
            Assert.Equal(["Launch Room"], Groups(state, "research"));
            Assert.Equal(["ivy", "notes"], Mirror(state).Rooms[key].Members.Select(m => m.Name).Order(StringComparer.Ordinal));

            // 4. Delete Group Chat: the room leaves the mirror (a tombstone) and every bot's groups.
            await manager.DeleteAsync(key);
            await sync.FlushNow();
            state = await State(url);
            Assert.Null(store.Room(key));
            Assert.False(Mirror(state).Rooms.ContainsKey(key));
            Assert.True(Mirror(state).Deleted.ContainsKey(key));
            Assert.Equal(["Launch Room", "Weekend Plans"], Groups(state, "ivy"));
            Assert.Equal(["Weekend Plans"], Groups(state, "notes"));
            Assert.False(sync.HasPending);
        }
        finally
        {
            sync.Shutdown();
            using var http = new HttpClient();
            await http.PostAsync(url.TrimEnd('/') + "/__settings/reset", new StringContent("{}"));
        }
    }
}
