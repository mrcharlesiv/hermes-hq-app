using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Net;
using Xunit;

namespace Hermes.Core.Tests;

/// A round in a real room over a real wire (HermesKit/Groups/GroupRounds.swift, GroupTurn.swift): settings-gateway.py
/// --group-rooms's Launch Room (ivy, research), read as the app reads it (profiles.list → BotStore → GroupSync.Pulled),
/// then your send driven by GroupEngine on one thread: each member's hidden session made with `session.create`
/// (room_plumbing), the room prompt submitted, the synthetic reply streamed and `message.complete` waking the turn, the
/// replies posted, and a second round where both pass. e2e.sh and windows.yml start that stand-in
/// (HQW_E2E_GROUPS_CREDENTIALS); without it this passes vacuously. The mirror is never written (no publish), so the
/// sidebar's test on the same stand-in reads the seed.
[Trait("Category", "E2E")]
public class GroupRoomEndToEndTests
{
    private const string Key = "id:rfixture-launch";

    [Fact]
    public async Task ARoundToTwoMemberBotsStreamsTheirRepliesIntoTheRoom()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_GROUPS_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);

        var gw = new ClientGateway(client);
        var bots = new BotStore(gw, new MemoryDeviceStore());
        await bots.RefreshAsync();
        var store = new GroupStore { Roster = new BotStoreGroupRoster(bots) };
        var sync = new GroupSync(store, gw);
        sync.Pulled(bots.DefaultProfileRow());
        sync.Shutdown();
        store.OnMirrorChange = null;   // this test never publishes: the stand-in's mirror stays the seed
        Assert.NotNull(store.Room(Key));

        using var loop = new GroupLoop();
        var engine = await loop.Run(() => new GroupEngine(store, new ClientGroupGateway(client),
            new GroupTiming { Poll = TimeSpan.FromSeconds(2), Base = TimeSpan.FromSeconds(60), HardCap = TimeSpan.FromSeconds(120) }));
        var replies = new List<string>();
        await loop.Run(() => { engine.OnReply = (_, entry, _) => replies.Add(entry.From.Name); return true; });
        var before = await loop.Run(() => store.Room(Key)!.Log.Count);
        try
        {
            var sent = Assert.IsType<GroupSendOutcome.Sent>(await loop.Run(() => engine.Send("Who has the release notes this week?", Key)));
            await loop.Until(() => store.Activity(Key).Any(e => e.Kind is GroupActivityKind.Settled or GroupActivityKind.Capped or GroupActivityKind.Cancelled)
                && !engine.IsDriving(Key), "the round settles", 60);
            var room = await loop.Run(() => store.Room(Key)!.Clone());
            var added = room.Log.Skip(before).ToList();
            Assert.Equal(["Who has the release notes this week?", "Ivy here: noted.", "Research here: noted."], added.Select(e => e.Text));
            Assert.Equal(sent.EntryId, added[0].Id);
            Assert.Equal(["You", "ivy", "research"], added.Select(e => e.From.Name));
            Assert.All(added, e => Assert.Equal(added[0].Thread, e.Thread));
            Assert.Equal(["ivy", "research"], replies);
            Assert.False(room.Running);
            Assert.Empty(room.Undelivered);
            Assert.Empty(room.Asking);
            Assert.Empty(room.Stranded);
            // Each member's hidden session for the thread is saved under its session key.
            Assert.Equal([$"thread:{added[0].Thread}::ivy", $"thread:{added[0].Thread}::research"], room.Sessions.Keys.Order(StringComparer.Ordinal));
            var activity = await loop.Run(() => store.Activity(Key).Select(e => $"{e.Kind}:{e.Member}").ToList());
            Assert.Equal(["Queued:", "Working:ivy", "Replied:ivy", "Working:research", "Replied:research", "Working:ivy", "Passed:ivy", "Settled:"], activity);
        }
        finally
        {
            await loop.Run(() => { engine.Shutdown(); return true; });
        }
    }
}
