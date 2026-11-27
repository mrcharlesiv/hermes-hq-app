using System.Globalization;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Net;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-57] The group-room-activity walk's path over a real wire, headless (Services/ProofWalks.GroupActivity.cs draws
/// the same): settings-gateway.py --group-rooms --quiet-room's Quiet Room is the empty room with an empty Activity; a
/// line in Launch Room, and its Activity reads newest first down to your send, each row timed, members by their names.
/// e2e.sh and windows.yml start that stand-in (HQW_E2E_GROUPACTIVITY_CREDENTIALS); without it this passes vacuously.
[Trait("Category", "E2E")]
public class GroupActivityEndToEndTests
{
    [Fact]
    public async Task QuietRoomIsEmptyAndLaunchRoomsActivityIsNewestFirst()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_GROUPACTIVITY_CREDENTIALS");
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
        Assert.NotNull(store.Room(GroupActivityWalkProof.QuietKey));
        Assert.NotNull(store.Room(GroupActivityWalkProof.LaunchKey));

        IReadOnlyList<GroupActivitySheet.Row> Sheet(string key) =>
            GroupActivitySheet.Rows(store.Activity(key), store.Labels(store.Seated(store.Room(key)!)), TimeZoneInfo.Local, CultureInfo.GetCultureInfo("en-US"));
        static List<(string, string)> Shown(IReadOnlyList<GroupActivitySheet.Row> rows) => [.. rows.Select(r => (r.Text, r.Time))];

        using var loop = new GroupLoop();
        var engine = await loop.Run(() => new GroupEngine(store, new ClientGroupGateway(client),
            new GroupTiming { Poll = TimeSpan.FromSeconds(2), Base = TimeSpan.FromSeconds(60), HardCap = TimeSpan.FromSeconds(120) }));
        var quiet = await loop.Run(() => GroupRoomSession.Open(GroupActivityWalkProof.QuietKey, store, engine, "acct")!);
        var launch = await loop.Run(() => GroupRoomSession.Open(GroupActivityWalkProof.LaunchKey, store, engine, "acct")!);
        try
        {
            // Quiet Room: nothing said, nobody typing: the empty room, its members by name, and an empty Activity.
            await loop.Run(() => { GroupRoomChrome.Open(quiet); return true; });
            Assert.Null(await loop.Run(() => GroupActivityWalkProof.EmptyRoom(GroupRoomChrome.IsEmpty(quiet.Messages, quiet.Typing), quiet.Title,
                GroupRowWords.MembersOrNone(quiet.MemberNames), GroupRoomChrome.EmptyHint)));
            var empty = await loop.Run(() => Sheet(GroupActivityWalkProof.QuietKey));
            Assert.Null(GroupActivityWalkProof.EmptyActivity(GroupActivitySheet.Title, Shown(empty), empty.Count == 0 ? GroupActivitySheet.Empty : null));

            // Launch Room: a line, its round; Activity newest first, down to your send.
            await loop.Run(() => { GroupRoomChrome.Open(launch); return true; });
            await loop.Run(() => { launch.Send(GroupActivityWalkProof.Line); return true; });
            await loop.Until(() => launch.RoomRunning, "the round runs", 10);
            await loop.Until(() => !launch.RoomRunning && !engine.IsDriving(GroupActivityWalkProof.LaunchKey), "the round's end", 60);
            var rows = await loop.Run(() => Sheet(GroupActivityWalkProof.LaunchKey));
            Assert.Null(GroupActivityWalkProof.Activity(GroupActivitySheet.Title, Shown(rows), emptyShown: false));
            Assert.Contains(rows, r => r.Text == "Ivy replied");
            Assert.Contains(rows, r => r.Text == "Research replied");
            Assert.All(rows, r => Assert.NotEqual("", r.Glyph));
        }
        finally
        {
            await loop.Run(() => { quiet.Dispose(); launch.Dispose(); engine.Shutdown(); return true; });
        }
    }
}
