using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-41] The group-room walk's path over a real wire, headless (Services/ProofWalks.GroupRoom.cs draws the same):
/// settings-gateway.py --group-rooms's Launch Room opened unread and read as it opens, the walk's line answered by both
/// members under their names (GroupRoomChrome.ShowsSenderName), then a second line stopped while its round runs.
/// e2e.sh and windows.yml start that stand-in (HQW_E2E_GROUPS_CREDENTIALS); without it this passes vacuously. Nothing is
/// published: the stand-in's mirror stays the seed for the sidebar's test.
[Trait("Category", "E2E")]
public class GroupRoomWalkEndToEndTests
{
    private const string Key = GroupRoomWalkProof.LaunchKey;

    [Fact]
    public async Task TheRoomOpensReadAnswersUnderNamesAndStopsMidRound()
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
        var sync = new GroupSync(store, gw);
        sync.Pulled(bots.DefaultProfileRow());
        sync.Shutdown();
        store.OnMirrorChange = null;
        Assert.NotNull(store.Room(Key));

        using var loop = new GroupLoop();
        var engine = await loop.Run(() => new GroupEngine(store, new ClientGroupGateway(client),
            new GroupTiming { Poll = TimeSpan.FromSeconds(2), Base = TimeSpan.FromSeconds(60), HardCap = TimeSpan.FromSeconds(120) }));
        var room = await loop.Run(() => GroupRoomSession.Open(Key, store, engine, "acct")!);
        try
        {
            await loop.Run(() => { store.SetUnread(Key, true); return true; });
            Assert.True(await loop.Run(() => store.Rows().Single(r => r.Id == Key).Unread));
            await loop.Run(() => { GroupRoomChrome.Open(room); return true; });
            var faces = await loop.Run(() => GroupRoomChrome.Faces(store, store.Room(Key)!).Select(f => f.Profile).ToList());
            Assert.Null(await loop.Run(() => GroupRoomWalkProof.Opened(room.Title, faces, store.Rows().Single(r => r.Id == Key).Unread)));

            List<(string?, string, string)> Rows()
            {
                var messages = room.Messages;
                return [.. messages.Select((m, i) => (GroupRoomChrome.ShowsSenderName(messages, i) ? m.Sender?.Name : null,
                    m.Role == Role.User ? "user" : m.Role == Role.Assistant ? "assistant" : "system", m.Text))];
            }
            await loop.Run(() => { room.Send(GroupRoomWalkProof.Line); return true; });
            await loop.Until(() => GroupRoomWalkProof.Replies(Rows()) == null && !room.RoomRunning && !engine.IsDriving(Key), "both replies and the round's end", 60);

            await loop.Run(() => { room.Send(GroupRoomWalkProof.StopLine); return true; });
            await loop.Until(() => room.RoomRunning, "the second round runs", 10);
            await loop.Run(() => room.StopRoomAsync());
            await loop.Until(() => !room.RoomRunning, "the round stops", 10);
            var activity = await loop.Run(() => store.Activity(Key).Select(a => a.Kind).ToList());
            var queued = activity.LastIndexOf(GroupActivityKind.Queued);
            Assert.Null(GroupRoomWalkProof.StoppedMidRound(activity.Skip(Math.Max(0, queued)).ToList(), await loop.Run(() => room.RoomRunning), stopShown: false));
        }
        finally
        {
            await loop.Run(() => { room.Dispose(); engine.Shutdown(); return true; });
        }
    }
}
