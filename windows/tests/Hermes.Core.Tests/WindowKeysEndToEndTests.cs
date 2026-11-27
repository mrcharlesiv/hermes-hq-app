using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Net;
using Hermes.Core.Sessions;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// View › Next Chat / Previous Chat (Ctrl+Down / Ctrl+Up) against the composer stand-in: the bots and the Sessions rows
/// the gateway really lists, walked as the shell walks them (WalkKeys over ChatWalk.BotOrder / SessionOrder), one row a
/// press, stopping at each end with no wraparound. Read only. Run through windows/scripts/e2e.sh; without the
/// credentials it passes vacuously.
[Collection(ComposerStandIn.Name)]
[Trait("Category", "E2E")]
public class WindowKeysEndToEndTests
{
    private static async Task<HermesClient?> SignInAsync()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
        if (path == null || !File.Exists(path)) return null;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(cred.Str("url")!), cred.Str("username")!, cred.Str("password")!);
        var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        return client;
    }

    /// Presses the key from `facts` until it is off, opening each target as the shell does; the rows visited.
    private static List<string> Walk(WalkFacts facts, bool forward, Func<string, WalkFacts> opened)
    {
        var seen = new List<string>();
        while (WalkKeys.Target(facts, forward) is { } key)
        {
            seen.Add(key);
            Assert.True(seen.Count <= 200, "the walk never stopped");
            facts = opened(key);
        }
        return seen;
    }

    [Fact]
    public async Task NextAndPreviousChatWalkTheGatewaysBotsAndSessionsWithoutWrapping()
    {
        if (await SignInAsync() is not { } client) return;
        await using var _ = client;
        var device = new MemoryDeviceStore();
        var bots = new BotStore(new ClientGateway(client), device);
        await bots.RefreshAsync();
        var sessions = new SessionStore(new ClientGateway(client), new MemoryDeviceStore());
        await sessions.RefreshAsync();

        var groups = BotList.SidebarGroups(bots.Sections, bots.Device.ShowHidden);
        var botOrder = ChatWalk.BotOrder(groups, bots.Device.Collapsed);
        var sessionOrder = ChatWalk.SessionOrder(sessions.Groups());
        Assert.True(botOrder.Count >= 2, $"the stand-in lists {botOrder.Count} bots");
        Assert.NotEmpty(sessionOrder);   // the stand-in lists Trip planning
        Assert.All(botOrder, id => Assert.NotNull(bots.Bot(id)));
        // Pins first, as the sidebar draws them.
        var pinned = groups.TakeWhile(g => g.Block == BotBlock.Tiles).SelectMany(g => g.Bots).Select(b => b.Id).Distinct().ToList();
        Assert.Equal(pinned, botOrder.Take(pinned.Count));

        // Bots: from "No Chat Open", Next opens the first bot's chat, then each bot once, stopping on the last.
        WalkFacts BotChat(string id) => new(OpenPane.BotChat, id, "bot-chat", null, false, botOrder, sessionOrder);
        var down = Walk(new WalkFacts(OpenPane.Nothing, null, null, null, false, botOrder, sessionOrder), forward: true, BotChat);
        Assert.Equal(botOrder, down);
        Assert.False(WalkKeys.Enabled(BotChat(botOrder[^1]), forward: true));   // no wraparound
        var up = Walk(BotChat(botOrder[^1]), forward: false, BotChat);
        Assert.Equal(botOrder.AsEnumerable().Reverse().Skip(1), up);
        Assert.False(WalkKeys.Enabled(BotChat(botOrder[0]), forward: false));

        // A collapsed group's bots are out of the walk.
        if (groups.FirstOrDefault(g => g.Bots.Count > 0 && g.Bots.All(b => groups.Count(o => o.Bots.Any(x => x.Id == b.Id)) == 1)) is { } fold)
        {
            var folded = ChatWalk.BotOrder(groups, [fold.Key]);
            Assert.DoesNotContain(folded, id => fold.Bots.Any(b => b.Id == id));
        }

        // Sessions: Trip planning, opened from Sessions, walks the Sessions rows the gateway lists; Sessions on show with
        // nothing beside it opens the first row.
        var trip = ChatWalk.SessionKey(sessions.LiveSummaries().Single(s => s.Id == WalkProof.TripStoredId).Profile, WalkProof.TripStoredId);
        Assert.Contains(trip, sessionOrder);
        Assert.Equal(sessionOrder[0], WalkKeys.Target(new WalkFacts(OpenPane.Place, null, null, "sessions", false, botOrder, sessionOrder), forward: true));
        WalkFacts SessionChat(string key)
        {
            var (profile, id) = ChatWalk.SplitSessionKey(key)!.Value;
            Assert.Contains(sessions.LiveSummaries(), s => s.Profile == profile && s.Id == id);
            return new(OpenPane.Chat, profile, id, null, true, botOrder, sessionOrder);
        }
        var at = sessionOrder.IndexOf(trip);
        Assert.Equal(sessionOrder.Skip(at + 1), Walk(SessionChat(trip), forward: true, SessionChat));
        Assert.Equal(sessionOrder.Take(at).Reverse(), Walk(SessionChat(trip), forward: false, SessionChat));
        // The same chat opened from the bots has no Bots row: Next goes to the first bot, Previous is off.
        var fromBots = SessionChat(trip) with { FromSessions = false };
        Assert.Equal(botOrder[0], WalkKeys.Target(fromBots, forward: true));
        Assert.False(WalkKeys.Enabled(fromBots, forward: false));
    }

    /// [WIN-39] CI run 44993175161: a chat started earlier (`/new`, session.create with no messages) is listed first once
    /// the chats listing is read again, so Next Chat on Sessions opens it, as the Mac's `walkTarget` reads `paneOrder` as
    /// it shows now. The walk must read the first row after Ctrl+R's read is applied (SessionStore.Reads, one per GET of
    /// the listing the stand-in served), never from the list as it stood before.
    [Fact]
    public async Task NextChatOnSessionsOpensTheFirstRowOfTheListingReadAgain()
    {
        var (url, session) = await QuickTileStandIns.SignInAsync("HQW_E2E_COMPOSER_CREDENTIALS");
        if (url.Length == 0) return;
        await QuickTileStandIns.Post(url, "/__composer/reset", new { });
        try
        {
            await using var client = new HermesClient(session);
            await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
            var sessions = new SessionStore(new ClientGateway(client), new MemoryDeviceStore());
            await sessions.RefreshAsync();
            WalkFacts OnSessions() => new(OpenPane.Place, null, null, "sessions", false, [], ChatWalk.SessionOrder(sessions.Groups()));
            var stale = OnSessions();
            var staleFirst = WalkKeys.Target(stale, forward: true);
            Assert.Equal(stale.Sessions[0], staleFirst);

            var started = await sessions.NewChatAsync("default");
            var startedKey = ChatWalk.SessionKey("default", started);
            Assert.NotEqual(startedKey, staleFirst);
            Assert.DoesNotContain(startedKey, OnSessions().Sessions);   // not listed until the listing is read again

            var reads = sessions.Reads;
            var mark = WalkProof.RestCount(await QuickTileStandIns.Get(url, "/__menus/state"));
            await sessions.RefreshAsync();                               // what Ctrl+R on Sessions calls
            var gets = WalkProof.ListReads(await QuickTileStandIns.Get(url, "/__menus/state"), mark);
            Assert.Equal(1, gets);
            Assert.Equal(reads + gets, sessions.Reads);
            var fresh = OnSessions();
            Assert.Equal(startedKey, fresh.Sessions[0]);
            Assert.Equal(startedKey, WalkKeys.Target(fresh, forward: true));
            Assert.NotEqual(staleFirst, WalkKeys.Target(fresh, forward: true));
        }
        finally { await QuickTileStandIns.Post(url, "/__composer/reset", new { }); }
    }
}
