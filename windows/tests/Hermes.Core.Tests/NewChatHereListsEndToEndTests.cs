using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Bots;
using Hermes.Core.Net;
using Hermes.Core.Sessions;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// New Chat Here (Ctrl+Alt+N, the Mac's ⌥⌘N: App/Root/KeyCommands.swift `hqNewChatHere` → SessionsOrganizer.swift
/// `newChat(like:)` at 93f984bb1) against the sessions stand-in (ci/fixtures/sessions-gateway.py), along the shell's own
/// route (Pages/ShellPage.xaml.cs `NewChatHere`): the open chat's facts (`ChatKeyState`), its live folder (the chat's
/// resume info, `ChatSession.Cwd`) and its list row, through `NewChatHere.Plan` to `SessionStore.NewChatAsync` (what
/// `NewChatWithAsync` calls), then the new chat opened as the pane opens it. The stand-in's own record shows one
/// `session.create` with the exact bot and folder, and the chat opens empty. Windows focus and the pane are not observed
/// here (managed and wire only). Run by windows/scripts/e2e-lists.sh; without HQW_E2E_SESSIONS it passes vacuously.
[Trait("Category", "E2E")]
[Collection(SessionsStandIn.Name)]
public class NewChatHereListsEndToEndTests
{
    private const string Home = "/home/hermes";

    private static async Task<JsonNode> StateAsync(string url)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url + "/__fixture/state"))!;
    }

    private sealed record Rig(string Url, HermesClient Client, SessionStore Store) : IAsyncDisposable
    {
        public ValueTask DisposeAsync() => Client.DisposeAsync();
    }

    private static async Task<Rig?> StartAsync()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_SESSIONS");
        if (path == null || !File.Exists(path)) return null;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!.TrimEnd('/');
        using (var http = new HttpClient()) await http.PostAsync(url + "/__fixture/reset", new StringContent("{}"));
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var store = new SessionStore(new ClientGateway(client), new MemoryDeviceStore()) { BotOrder = ["default", "research", "deploys"] };
        return new Rig(url, client, store);
    }

    private static async Task LoadAsync(SessionStore store)
    {
        await store.RefreshAsync();
        await store.LoadProjectsAsync(force: true);
    }

    /// The shell's route with `id` open as `pane`: the chat's live folder from its own open, its list row's, the plan,
    /// then (when the key is on) the one start, as ShellPage.NewChatHere → NewChatWithAsync. Returns the live folder seen,
    /// the plan and the new chat's id (null when nothing was started).
    private static async Task<(string? Live, NewChatHereStart? Plan, string? Id)> PressAsync(Rig rig, OpenPane pane, string profile, string id,
        bool group = false)
    {
        await using var open = rig.Client.OpenChat(profile, id, "open");
        await open.OpenAsync();
        var state = new ChatKeyState(pane, profile, id, Group: group);
        var plan = NewChatHere.Plan(state, open.Cwd, rig.Store.Row(profile, id)?.Cwd, rig.Store.ProjectsByProfile);
        return (open.Cwd, plan, plan == null ? null : await rig.Store.NewChatAsync(plan.Profile, plan.Folder));
    }

    /// The new chat as the pane opens it (`Navigator.Go(new ChatDestination(bot, id, "New Chat"))` → ChatPage): bound and
    /// empty, its history not read (the Mac's `startsNew`), and nothing sent.
    private static async Task LandsEmptyAsync(Rig rig, string profile, string id)
    {
        Assert.StartsWith("s-new-", id);
        await using var chat = rig.Client.OpenChat(profile, id, "New Chat");
        await chat.OpenAsync();
        Assert.Empty(chat.Messages);
        Assert.False(chat.HasOlder);
        Assert.NotNull(chat.RuntimeId);
        var resumes = (await StateAsync(rig.Url))["rpc"]!.AsArray()
            .Count(c => c?["method"]?.GetValue<string>() == "session.resume" && c?["params"]?["session_id"]?.GetValue<string>() == id);
        Assert.Equal(1, resumes);
    }

    [Fact]
    public async Task AChatInANestedFolderStartsTheNewOneAtItsProjectsRoot()
    {
        await using var rig = await StartAsync();
        if (rig == null) return;
        // Quarterly budget (Hermes) moved into a folder inside Website (/home/hermes/site): still Website's.
        await rig.Client.Rpc.RequestAsync("session.workspace.move",
            new JsonObject { ["cwd"] = $"{Home}/site/drafts/q3", ["session_key"] = "s-budget", ["profile"] = "default" }, TimeSpan.FromSeconds(10));
        await LoadAsync(rig.Store);
        Assert.Equal($"{Home}/site/drafts/q3", rig.Store.Row("default", "s-budget")?.Cwd);

        var mark = WalkProof.RpcCount(await StateAsync(rig.Url));
        var (live, plan, id) = await PressAsync(rig, OpenPane.Chat, "default", "s-budget");
        Assert.Equal($"{Home}/site/drafts/q3", live);
        Assert.Equal(new NewChatHereStart("default", $"{Home}/site"), plan);
        Assert.Null(NewChatHere.StartedOnce(await StateAsync(rig.Url), mark, "default", $"{Home}/site"));
        await LandsEmptyAsync(rig, "default", id!);
    }

    [Fact]
    public async Task AChatInNoProjectStartsTheNewOneAtHomeWithItsBot()
    {
        await using var rig = await StartAsync();
        if (rig == null) return;
        await LoadAsync(rig.Store);
        // Bread recipes (Research) sits in /home/hermes/app, which is Hermes's and Deploys's App but none of Research's.
        Assert.Equal($"{Home}/app", rig.Store.Row("research", "s-recipes")?.Cwd);
        Assert.Contains(rig.Store.ProjectsByProfile["deploys"], p => p.Root == $"{Home}/app");

        var mark = WalkProof.RpcCount(await StateAsync(rig.Url));
        var (_, plan, id) = await PressAsync(rig, OpenPane.Chat, "research", "s-recipes");
        Assert.Equal(new NewChatHereStart("research", null), plan);
        Assert.Null(NewChatHere.StartedOnce(await StateAsync(rig.Url), mark, "research", null));
        await LandsEmptyAsync(rig, "research", id!);
    }

    /// A bot's own chat is hidden from the lists, so it has no row: its folder is the live chat's, as the Mac's
    /// `chat.workingDirectory` is (the row-only route started it at Home).
    [Fact]
    public async Task ABotsOwnChatStartsInTheProjectHoldingItsLiveFolder()
    {
        await using var rig = await StartAsync();
        if (rig == null) return;
        await LoadAsync(rig.Store);
        var deploys = (await rig.Client.BotsAsync()).Single(b => b.Name == "deploys");
        var botChat = await rig.Client.BotChatIdAsync(deploys);
        Assert.Null(rig.Store.Row("deploys", botChat));
        Assert.Null(NewChatHere.Plan(new ChatKeyState(OpenPane.BotChat, "deploys", botChat), null, null, rig.Store.ProjectsByProfile)!.Folder);

        var mark = WalkProof.RpcCount(await StateAsync(rig.Url));
        var (live, plan, id) = await PressAsync(rig, OpenPane.BotChat, "deploys", botChat);
        Assert.Equal($"{Home}/app", live);
        Assert.Equal(new NewChatHereStart("deploys", $"{Home}/app"), plan);
        Assert.Null(NewChatHere.StartedOnce(await StateAsync(rig.Url), mark, "deploys", $"{Home}/app"));
        await LandsEmptyAsync(rig, "deploys", id!);
    }

    /// Off with a group chat, a place's page or nothing on show: no plan and no call at all.
    [Fact]
    public async Task AGroupAPageOrNothingStartsNoChat()
    {
        await using var rig = await StartAsync();
        if (rig == null) return;
        await LoadAsync(rig.Store);
        var mark = WalkProof.RpcCount(await StateAsync(rig.Url));
        var (_, plan, id) = await PressAsync(rig, OpenPane.Chat, "default", "s-budget", group: true);
        Assert.Null(plan);
        Assert.Null(id);
        foreach (var off in new[] { new ChatKeyState(OpenPane.Place, null, null), new ChatKeyState(OpenPane.Nothing, null, null) })
            Assert.Null(NewChatHere.Plan(off, $"{Home}/site", $"{Home}/site", rig.Store.ProjectsByProfile));
        Assert.Null(NewChatHere.StartedNothing(await StateAsync(rig.Url), mark));
    }
}
