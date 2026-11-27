using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Net;
using Xunit;

namespace Hermes.Core.Tests;

/// The group chats mirror (HermesKit/Groups/GroupSync.swift) against a real wire: the default profile's
/// `ui_meta["hermes-bots-groups"]` through `profiles.list` / `profiles.configure` with Hermes' per-key compare-and-swap,
/// as windows/ci/fixtures/settings-gateway.py ports it. No new stand-in: e2e.sh already starts that one
/// (HQW_E2E_SETTINGS_CREDENTIALS); without it these pass vacuously.
[Trait("Category", "E2E")]
public class GroupsEndToEndTests
{
    private static async Task Post(string url, string path, object body)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");
        (await http.PostAsync(url.TrimEnd('/') + path, content)).EnsureSuccessStatusCode();
    }

    private static async Task<JsonNode?> Mirror(string url)
    {
        using var http = new HttpClient();
        var state = JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + "/__settings/state"))!;
        return state.Obj("profiles").Obj("default").Obj("ui_meta").Get(GroupSnapshot.MetaKey)?.DeepClone();
    }

    [Fact]
    public async Task TheMirrorPublishesTakesInAnotherDevicesRoomAndRetriesARefusedWrite()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_SETTINGS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Post(url, "/__settings/reset", new { });
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);

        var room = new GroupRoom("Launch Room", "rfixture-launch") { Members = [new GroupMember("ivy", "ivy"), new GroupMember("research", "research")] };
        var store = new GroupStore([room]);
        var sync = new GroupSync(store, new ClientGateway(client)) { Debounce = TimeSpan.FromSeconds(60), BackoffUnitSeconds = 60 };
        try
        {
            // 1. A first send: the mirror is written at revision 1.
            store.Append(new GroupMessage(null, 1_790_000_000_000, GroupAuthor.You, "Who takes the notes?", "tfixture-1"), "id:rfixture-launch");
            await sync.FlushNow();
            Assert.False(sync.HasPending);
            Assert.Equal(1, sync.RemoteRevision);
            var first = GroupSnapshot.Parse(await Mirror(url));
            Assert.Equal(["id:rfixture-launch"], first.Rooms.Keys);
            Assert.Equal("Who takes the notes?", first.Rooms["id:rfixture-launch"].Log.Single().Text);
            Assert.Equal(1, first.Rooms["id:rfixture-launch"].Revision);

            // 2. Another device adds a room (revision 2). The next publish reads it first, keeps it, and swaps at 2 → 3.
            var desk = new GroupRoom("Desk Room", "rfixture-desk") { SyncRevision = 1, Members = [new GroupMember("ivy", "ivy")] };
            desk.Log.Add(new GroupMessage("desk-1", 1_790_000_100_000, new GroupAuthor(GroupAuthorKind.Member, "ivy"), "From the desktop", "tfixture-2"));
            var both = GroupSnapshot.Merge(first, GroupSnapshot.Local([desk], new Dictionary<string, int>()), writeRevision: 1);
            await Post(url, "/__settings/desktop-edit", new { profile = "default", key = GroupSnapshot.MetaKey,
                value = System.Text.Json.JsonDocument.Parse(GroupSnapshot.Envelope(both, 1_790_000_100_000).Json.ToJsonString()).RootElement });
            store.Append(new GroupMessage(null, 1_790_000_200_000, GroupAuthor.You, "@ivy you take them", "tfixture-1"), "id:rfixture-launch");
            await sync.FlushNow();
            Assert.False(sync.HasPending);
            Assert.Equal(3, sync.RemoteRevision);
            Assert.Equal(["id:rfixture-desk", "id:rfixture-launch"], store.Rooms.Select(r => r.Key).Order(StringComparer.Ordinal));
            var second = GroupSnapshot.Parse(await Mirror(url));
            Assert.Equal(["id:rfixture-desk", "id:rfixture-launch"], second.Rooms.Keys.Order(StringComparer.Ordinal));
            Assert.Equal(["Who takes the notes?", "@ivy you take them"], second.Rooms["id:rfixture-launch"].Log.Select(e => e.Text));
            Assert.Equal("From the desktop", second.Rooms["id:rfixture-desk"].Log.Single().Text);

            // 3. A refused write (applied: false) keeps the change pending; the next try lands it.
            await Post(url, "/__settings/fail", new { method = "profiles.configure", mode = "applied-false", count = 1 });
            store.Append(new GroupMessage(null, 1_790_000_300_000, GroupAuthor.You, "Thanks", "tfixture-1"), "id:rfixture-launch");
            await sync.FlushNow();
            Assert.True(sync.HasPending);
            await sync.FlushNow();
            Assert.False(sync.HasPending);
            Assert.Equal("Thanks", GroupSnapshot.Parse(await Mirror(url)).Rooms["id:rfixture-launch"].Log[^1].Text);

            // 4. Delete Group Chat elsewhere: a tombstone in the mirror removes the room here on the next pull.
            var tomb = GroupSnapshot.Parse(await Mirror(url));
            tomb.Rooms.Remove("id:rfixture-desk");
            tomb.Deleted["id:rfixture-desk"] = 9;
            await Post(url, "/__settings/desktop-edit", new { profile = "default", key = GroupSnapshot.MetaKey,
                value = System.Text.Json.JsonDocument.Parse(GroupSnapshot.Envelope(tomb, 1_790_000_400_000).Json.ToJsonString()).RootElement });
            var list = await client.Rpc.RequestAsync("profiles.list", new JsonObject { ["include_sessions"] = false }, TimeSpan.FromSeconds(20));
            sync.Pulled(list.Arr("profiles")!.First(p => p.Str("name") == "default"));
            Assert.Equal(["id:rfixture-launch"], store.Rooms.Select(r => r.Key));
            Assert.Equal(9, store.Tombstones["id:rfixture-desk"]);
        }
        finally
        {
            sync.Shutdown();
            await Post(url, "/__settings/reset", new { });
        }
    }
}
