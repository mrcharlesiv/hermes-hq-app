using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Groups;
using Hermes.Core.Net;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// The sidebar's group chat rows from a real wire: settings-gateway.py --group-rooms (two rooms in the default profile's
/// `ui_meta["hermes-bots-groups"]`, their members naming them in `hermes-bots.groups`), read as the app reads it
/// (`profiles.list` → BotStore → GroupSync.Pulled → GroupStore.Rows → BotListRooms.Compose → BotList.SidebarGroups), and
/// laid out as the CI walk "sidebar-group-chats" expects (WalkProof.SidebarGroupChats). e2e.sh and windows.yml start that
/// stand-in (HQW_E2E_GROUPS_CREDENTIALS); without it this passes vacuously.
[Trait("Category", "E2E")]
public class GroupSidebarEndToEndTests
{
    [Fact]
    public async Task TheStandInsRoomsAreRowsUnderUnassignedAmongItsBotNewestFirst()
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
        var groups = new GroupStore { Roster = new BotStoreGroupRoster(bots) };
        var sync = new GroupSync(groups, gw);
        sync.Pulled(bots.DefaultProfileRow());
        var rooms = groups.Rows();
        Assert.Equal(["Launch Room", "Weekend Plans"], rooms.OrderByDescending(r => r.LastAt).Select(r => r.Name));
        var launch = rooms.Single(r => r.Name == "Launch Room");
        Assert.Equal(["ivy", "research"], launch.Faces.Select(f => f.Profile));
        Assert.Equal(WalkProof.GroupChatsLaunchLabel, BotListRooms.AccessibilityLabel(launch));
        Assert.Equal(["ivy", "notes"], rooms.Single(r => r.Name == "Weekend Plans").Faces.Select(f => f.Profile));

        var (sections, count) = BotListRooms.Compose(bots.Sections, rooms, bots.Device.Sections);
        Assert.Equal(2, count);
        var sidebar = BotList.SidebarGroups(sections, bots.Device.ShowHidden);
        Assert.Null(WalkProof.SidebarGroupChats(Keys(sidebar, rail: false), rail: false));
        Assert.Null(WalkProof.SidebarGroupChats(Keys(sidebar, rail: true), rail: true));
        // Reading the mirror writes nothing back.
        await Task.Delay(1000);
        Assert.False(sync.HasPending);
        Assert.Equal(0, sync.Publishes);
        sync.Shutdown();
    }

    /// The rows as ShellPage.Items draws them (headings open, lines between groups in the rail).
    private static List<string> Keys(IReadOnlyList<BotListSection> groups, bool rail)
    {
        var keys = new List<string>();
        foreach (var g in groups)
        {
            if (rail) { if (g.Heads.Count == 0) continue; if (keys.Count > 0) keys.Add("divider"); }
            else keys.Add("header:" + g.Title);
            keys.AddRange(g.Heads.Select(h => h.Key));
        }
        return keys;
    }
}
