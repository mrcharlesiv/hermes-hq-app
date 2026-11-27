using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Net;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests;

/// The New Chat sheet (Ctrl+Shift+N, Compose) against the sessions stand-in (ci/fixtures/sessions-gateway.py): the
/// sheet's list from `projects.tree`, a pick of another bot's project and of the lit bot's own, each started through
/// `SessionStore.NewChatAsync(bot, folder)` — the stand-in records `session.create` with that folder as `cwd`
/// (`cwd_explicit`). Run by windows/scripts/e2e-lists.sh (its filter takes every *ListsEndToEnd* class); without
/// HQW_E2E_SESSIONS it passes vacuously.
[Trait("Category", "E2E")]
[Collection(SessionsStandIn.Name)]
public class NewChatListsEndToEndTests
{
    private const string Home = "/home/hermes";

    private static async Task<JsonNode> GetAsync(string url)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url))!;
    }

    private static async Task<JsonNode?> CreateCallAsync(string url, int after)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (true)
        {
            var calls = (await GetAsync(url + "/__fixture/state"))["rpc"]!.AsArray()
                .Where(c => c?["method"]?.GetValue<string>() == "session.create").ToList();
            if (calls.Count > after) return calls[after]!["params"];
            if (DateTime.UtcNow > deadline) return null;
            await Task.Delay(200);
        }
    }

    [Fact]
    public async Task APickedProjectStartsTheChatInItsFolder()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_SESSIONS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!.TrimEnd('/');
        using (var http = new HttpClient()) await http.PostAsync(url + "/__fixture/reset", new StringContent("{}"));
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var store = new SessionStore(new ClientGateway(client), new MemoryDeviceStore()) { BotOrder = ["default", "research", "deploys"] };
        await store.RefreshAsync();
        await store.LoadProjectsAsync(force: true);

        // The sheet's list: every bot's saved projects, one per folder, A to Z (App is two bots' but listed once).
        var entries = NewChatCompose.Entries(store.ProjectsByProfile, store.BotOrder);
        Assert.Equal(["App", "Reading", "Website"], entries.Select(e => e.Label));
        Assert.All(entries, e => Assert.False(e.IsFolder));
        var bots = new NewChatBot[] { new("default", "Hermes"), new("research", "Research"), new("deploys", "Deploys") };
        var last = new NewChatLast(new MemoryDeviceStore());
        var step = NewChatCompose.Decide(SessionFilterWords.EffectiveProjects(store.FilterState()), null, false, bots);
        Assert.Equal(new NewChatStep.Sheet(null), step);
        var sheet = new NewChatSheetModel(bots, entries, null, last,
            bot => NewChatCompose.Recent(bot, last, store.LiveSummaries(), store.ProjectsByProfile));
        Assert.Equal("default", sheet.Bot);
        var layout = sheet.Layout();
        Assert.Equal(["App", "Reading", "Website"], layout.Projects.Select(r => r.Entry.Label));
        Assert.False(layout.NewProjectInProjects);

        var before = (await GetAsync(url + "/__fixture/state"))["rpc"]!.AsArray().Count(c => c?["method"]?.GetValue<string>() == "session.create");

        // Hermes in Reading (Research's project): the chat starts in its folder.
        var reading = layout.Projects.Single(r => r.Entry.Label == "Reading").Entry.Key;
        sheet.Note(reading);
        var folder = NewChatCompose.Folder(reading, sheet.Bot, store.ProjectsByProfile);
        Assert.Equal($"{Home}/reading", folder);
        var id = await store.NewChatAsync(sheet.Bot, folder);
        Assert.StartsWith("s-new-", id);
        var call = await CreateCallAsync(url, before);
        Assert.NotNull(call);
        Assert.Equal("default", call!["profile"]?.GetValue<string>());
        Assert.Equal($"{Home}/reading", call["cwd"]?.GetValue<string>());
        Assert.True(call["cwd_explicit"]?.GetValue<bool>());
        Assert.Equal("desktop", call["source"]?.GetValue<string>());

        // The next sheet opens on Hermes with "Last used" on Reading; Research lit, Start Chat: no project, no folder.
        var again = new NewChatSheetModel(bots, entries, null, last);
        Assert.Equal("default", again.Bot);
        Assert.True(again.Layout().Projects.Single(r => r.Entry.Label == "Reading").LastUsed);
        again.Bot = "research";
        again.Note(null);
        var plain = await store.NewChatAsync(again.Bot, NewChatCompose.Folder(null, again.Bot, store.ProjectsByProfile));
        Assert.StartsWith("s-new-", plain);
        call = await CreateCallAsync(url, before + 1);
        Assert.NotNull(call);
        Assert.Equal("research", call!["profile"]?.GetValue<string>());
        Assert.Null(call["cwd"]);
        Assert.Equal("research", last.Bot);
    }

    /// The new-chat-sheet screenshot walk's expectations (Hermes.Core.Shell.WalkProof) hold on this stand-in: Research is
    /// the second pill, its project Reading starts the chat in WalkProof.NewChatFolder, and the record the walk reads
    /// passes WalkProof.NewChatStartedIn. In this class so it never runs beside the test above (both reset the stand-in).
    [Fact]
    public async Task TheSheetWalksPickStartsResearchInReading()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_SESSIONS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!.TrimEnd('/');
        using (var http = new HttpClient()) await http.PostAsync(url + "/__fixture/reset", new StringContent("{}"));
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var roster = await client.BotsAsync();
        var store = new SessionStore(new ClientGateway(client), new MemoryDeviceStore()) { BotOrder = [.. roster.Select(b => b.Name)] };
        await store.RefreshAsync();
        await store.LoadProjectsAsync(force: true);

        var bots = roster.Select(b => new NewChatBot(b.Name, b.DisplayName)).ToList();
        var sheet = new NewChatSheetModel(bots, NewChatCompose.Entries(store.ProjectsByProfile, store.BotOrder), null,
            new NewChatLast(new MemoryDeviceStore()));
        Assert.Equal("default", sheet.Bots[0].Id);
        Assert.Equal(Hermes.Core.Shell.WalkProof.NewChatBot, sheet.Bots[1].Id);
        sheet.Bot = sheet.Bots[1].Id;
        var row = Assert.Single(sheet.Layout().Projects, r => r.Entry.Label == Hermes.Core.Shell.WalkProof.NewChatProject);
        var folder = NewChatCompose.Folder(row.Entry.Key, sheet.Bot, store.ProjectsByProfile);
        Assert.Equal(Hermes.Core.Shell.WalkProof.NewChatFolder, folder);

        var mark = Hermes.Core.Shell.WalkProof.RpcCount(await GetAsync(url + "/__fixture/state"));
        Assert.StartsWith("s-new-", await store.NewChatAsync(sheet.Bot, folder));
        Assert.Null(Hermes.Core.Shell.WalkProof.NewChatStartedIn(await GetAsync(url + "/__fixture/state"), mark,
            Hermes.Core.Shell.WalkProof.NewChatBot, Hermes.Core.Shell.WalkProof.NewChatFolder));
    }

    /// A chat the sheet just started opens empty and bound, never on "This chat isn't on the gateway anymore". Hermes
    /// stores a `session.create` chat with its first prompt (tui_gateway contracts/sessions.py), so until then its REST
    /// read answers 404 (LiveChatSession.swift `tailReadFailures`); the Mac's open of a chat it just made skips the first
    /// page and only resumes (`startsNew`, LiveChatSession.swift `open`: "A chat just made has no stored rows yet").
    [Fact]
    public async Task AChatJustStartedOpensEmptyWithoutReadingItsHistory()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_SESSIONS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!.TrimEnd('/');
        using (var http = new HttpClient()) await http.PostAsync(url + "/__fixture/reset", new StringContent("{}"));
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var store = new SessionStore(new ClientGateway(client), new MemoryDeviceStore()) { BotOrder = ["default", "research", "deploys"] };
        await store.RefreshAsync();

        var id = await store.NewChatAsync("research", Hermes.Core.Shell.WalkProof.NewChatFolder);
        Assert.StartsWith("s-new-", id);
        // The gateway's contract, as the stand-in keeps it: no stored rows (and no REST read) before the first prompt.
        var gone = await Assert.ThrowsAsync<GatewayException>(() => client.HistoryAsync("research", id, 24, 0));
        Assert.Equal(404, gone.Status);

        await using var chat = client.OpenChat("research", id, "New Chat");
        await chat.OpenAsync();   // threw GatewayException 404 → the chat page's "This chat isn't on the gateway anymore."
        Assert.Empty(chat.Messages);
        Assert.False(chat.HasOlder);
        Assert.NotNull(chat.RuntimeId);
        var resumes = (await GetAsync(url + "/__fixture/state"))["rpc"]!.AsArray()
            .Count(c => c?["method"]?.GetValue<string>() == "session.resume" && c?["params"]?["session_id"]?.GetValue<string>() == id);
        Assert.Equal(1, resumes);

        // Only the open right after the start skips the read: the next open of that id reads its history again.
        await using var again = client.OpenChat("research", id, "New Chat");
        await Assert.ThrowsAsync<GatewayException>(() => again.OpenAsync());
    }
}

/// The tests that reset and drive sessions-gateway.py (ListsEndToEndTests, NewChatListsEndToEndTests): one at a time, so
/// one class's reset or `session.create` never lands in the middle of another's reads.
[CollectionDefinition(Name, DisableParallelization = true)]
public class SessionsStandIn { public const string Name = "sessions stand-in"; }
