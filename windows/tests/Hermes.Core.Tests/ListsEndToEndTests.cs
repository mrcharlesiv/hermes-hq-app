using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Net;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests;

/// The Bots and Sessions lists against the stand-in gateways (scripts/fixtures/botslist-gateway.py and
/// sessions-gateway.py). Run through windows/scripts/e2e-lists.sh, which starts both and sets HQW_E2E_BOTSLIST and
/// HQW_E2E_SESSIONS; without them these tests pass vacuously.
[Trait("Category", "E2E")]
[Collection(SessionsStandIn.Name)]
public class ListsEndToEndTests
{
    private static async Task<(HermesClient Client, string Url)?> SignInAsync(string variable)
    {
        var path = Environment.GetEnvironmentVariable(variable);
        if (path == null || !File.Exists(path)) return null;
        var j = JsonNode.Parse(File.ReadAllText(path))!;
        var url = j.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), j.Str("username")!, j.Str("password")!);
        var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        return (client, url);
    }

    private static async Task<JsonNode> GetAsync(string url)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url))!;
    }

    [Fact]
    public async Task BotsListReadsAndWrites()
    {
        if (await SignInAsync("HQW_E2E_BOTSLIST") is not var (client, url)) return;
        await using var _ = client;
        var store = new BotStore(new ClientGateway(client), new MemoryDeviceStore());
        await store.RefreshAsync();
        Assert.True(store.HasRoster);
        Assert.Contains(store.Rows, b => b.Id == "default" && b.Name == "Hermes");
        var ivy = store.Bot("ivy")!;

        // Pin: one profiles.configure carrying the whole merged meta, the flag and its section together.
        await store.SetPinnedAsync("ivy", ivy.Name, true);
        Assert.True(store.Bot("ivy")!.Pinned);
        var state = await GetAsync(url + "/__settings/state");
        var meta = state["profiles"]!["ivy"]!["ui_meta"]!["hermes-bots"]!;
        Assert.True(meta["pinned"]!.GetValue<bool>());
        Assert.Equal("hermes-hq-pinned", meta["sectionId"]!.GetValue<string>());
        await store.SetPinnedAsync("ivy", ivy.Name, false);
        Assert.False(store.Bot("ivy")!.Pinned);

        // A section, a bot moved into it, the section renamed (its member re-stamped), then hidden and shown.
        var clients = store.AppendSection("Clients");
        await store.MoveAsync("ivy", ivy.Name, clients.Id);
        await store.RenameSectionAsync(clients.Id, "Customers");
        state = await GetAsync(url + "/__settings/state");
        Assert.Equal("Customers", state["profiles"]!["ivy"]!["ui_meta"]!["hermes-bots"]!["sectionName"]!.GetValue<string>());
        await store.SetHiddenAsync("ivy", ivy.Name, true);
        Assert.Contains(store.Layout.Hidden, b => b.Id == "ivy");
        await store.SetHiddenAsync("ivy", ivy.Name, false);

        // Edit Bot: the name (meta title) and the description in one call.
        var outcome = await store.SaveEditAsync("ivy", "Ivy Two", "Reads everything");
        Assert.True(outcome.Succeeded, outcome.Reason);
        await store.RefreshAsync();
        Assert.Equal("Ivy Two", store.Bot("ivy")!.Name);
        Assert.Equal("Reads everything", store.Bot("ivy")!.Role);

        // The bot's own chat: the roster's, else the registry's (minted when there is none).
        var chat = await store.BotChatIdAsync("ivy");
        Assert.False(string.IsNullOrEmpty(chat));

        // New Bot, Duplicate, Delete.
        var made = await store.CreateBotAsync("Scout", "", "Finds things");
        Assert.Equal("scout", made.Name);
        await store.RefreshAsync();
        Assert.Contains(store.Rows, b => b.Id == "scout");
        var copy = await store.DuplicateAsync("scout", "Scout");
        Assert.Equal("scout-2", copy);
        await store.DeleteAsync("scout-2", "Scout");
        await store.RefreshAsync();
        Assert.DoesNotContain(store.Rows, b => b.Id == "scout-2");
        state = await GetAsync(url + "/__settings/state");
        Assert.Contains(state["writes"]!.AsArray(), w => w?.ToJsonString().Contains("DELETE /api/profiles/scout-2") == true);
    }

    [Fact]
    public async Task SessionsListReadsFiltersAndEdits()
    {
        if (await SignInAsync("HQW_E2E_SESSIONS") is not var (client, url)) return;
        await using var _ = client;
        using (var http = new HttpClient()) await http.PostAsync(url + "/__fixture/reset", new StringContent("{}"));
        var store = new SessionStore(new ClientGateway(client), new MemoryDeviceStore());
        await store.RefreshAsync();
        Assert.Null(store.Failure);
        var live = store.LiveSummaries();
        Assert.Contains(live, s => s.Id == "s-garden");
        Assert.DoesNotContain(live, s => s.Id == "s-run");                 // a background run stays off
        Assert.DoesNotContain(live, s => s.Title == "Bot Chat");
        Assert.True(live.First(s => s.Id == "s-release").Pinned);
        Assert.True(live.First(s => s.Id == "s-budget").Unread);
        Assert.Equal("Pinned", store.Groups()[0].Title);

        store.ApplyFilter(new(SessionFilterActionKind.Runs), "default");
        Assert.Contains(store.LiveSummaries(), s => s.Id == "s-run");
        store.ApplyFilter(new(SessionFilterActionKind.Runs), "default");

        // Projects: the tree per bot, Group By Project, a project's page.
        await store.LoadProjectsAsync();
        Assert.Contains(store.ProjectEntries(), e => e.Label == "Website");
        store.ApplyFilter(new(SessionFilterActionKind.Group, SessionGroupBy.Project), "default");
        Assert.Contains(store.Groups(), g => g.Title == "Website");
        store.Prefs.ProjectFilter.Add(store.ProjectEntries().First(e => e.Label == "Website").Key);
        Assert.Equal(SessionListPipeline.PageId, store.Groups()[0].Id);
        store.ApplyFilter(new(SessionFilterActionKind.Group, SessionGroupBy.Date), "default");

        // Edits through the fixture's PATCH (pinned, unread, title, archived) and the reads that show them.
        var garden = store.LiveSummaries().First(s => s.Id == "s-garden");
        await store.SetPinnedAsync(garden, true);
        await store.RenameAsync(garden, "Spring garden");
        await store.SetUnreadAsync(garden, true);
        await store.RefreshAsync();
        garden = store.LiveSummaries().First(s => s.Id == "s-garden");
        Assert.True(garden.Pinned);
        Assert.Equal("Spring garden", garden.Title);
        Assert.True(garden.Unread);
        await store.OpenedAsync(garden.Profile, garden.Id);
        Assert.False(store.LiveSummaries().First(s => s.Id == "s-garden").Unread);
        await store.SetArchivedAsync(garden, true);
        await store.LoadArchivedAsync();
        Assert.Contains(store.ArchivedSummaries(), s => s.Id == "s-garden");
        var log = await GetAsync(url + "/__fixture/state");
        var patches = log["rest"]!.AsArray().Where(r => r!["method"]!.GetValue<string>() == "PATCH").ToList();
        Assert.Contains(patches, p => p!["body"]!["archived"]?.GetValue<bool>() == true && p["body"]!["profile"]!.GetValue<string>() == "default");

        // Compose: a new chat in a bot, opened by its stored id.
        var made = await store.NewChatAsync("research");
        Assert.False(string.IsNullOrEmpty(made));

        // The live registry (session.active_list) answers without error.
        await store.ReadLiveAsync();
    }
}
