using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-CHAT-HERE-PROOF] The walk for File › New Chat Here (Ctrl+Alt+N, the Mac's ⌥⌘N: KeyCommands.swift `hqNewChatHere`,
/// SessionsOrganizer.swift `newChat(like:)`) on the sessions stand-in (ci/fixtures/sessions-gateway.py). It goes through
/// the shell's own command (ShellPage.NewChatHere, the method Ctrl+Alt+N's accelerator calls), never through injected
/// keys, so it proves the route from the open chat to the gateway, not the key itself (ChatKeysTests and the shortcuts
/// sheet hold the key):
///   new-chat-here  Quarterly budget (Hermes) moved into /home/hermes/site/drafts/q3: New Chat Here makes one
///                  session.create for Hermes in Website's root /home/hermes/site, explicit; Bread recipes (Research, in
///                  a folder no project of Research's holds): one for Research with no folder; Deploys's own chat (no
///                  list row; its live folder /home/hermes/app is App's): one for Deploys in /home/hermes/app. Each time a
///                  "New Chat" opens in the pane, empty (pictures new-chat-here-project, new-chat-here-home,
///                  new-chat-here-bot). With the Sessions page on show, or nothing after Close Chat, it makes nothing.
///                  The message box's keyboard focus is logged, not asserted (unobserved on Windows so far).
/// windows/ci/windows.yml runs this after "new-chat-sheet" on the synthetic sessions gateway.
internal static partial class ProofWalks
{
    private const string HereNested = "/home/hermes/site/drafts/q3", HereNestedHome = "/home/hermes/site";

    private static void RegisterNewChatHereWalks()
    {
        Automation.NamedWalks["new-chat-here"] = NewChatHereAsync;
    }

    private static async Task NewChatHereAsync(Func<string, Task> shot)
    {
        var lifetime = App.Window!.Lifetime;
        lifetime.RequireOpen();
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        var hub = await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Bots.Bot("deploys") != null ? h : null, "the roster");

        // Don't cancel a write on the fixture socket mid-frame: both the admitted move and its undo
        // have their own RPC deadline. Cancelling the visit stops its reads, not the rollback's transport.
        async Task MoveAsync(string cwd) => await client.Rpc.RequestAsync("session.workspace.move",
            new JsonObject { ["cwd"] = cwd, ["session_key"] = "s-budget", ["profile"] = "default" }, TimeSpan.FromSeconds(10));

        // A chat in a folder nested inside a project: the new chat at the project's root, with the same bot.
        await lifetime.WithFixtureChangeAsync(() => MoveAsync(HereNested), async () =>
        {
            await hub.Sessions.RefreshAsync(lifetime.StopToken);
            lifetime.RequireOpen();
            await hub.Sessions.LoadProjectsAsync(force: true, ct: lifetime.StopToken);
            lifetime.RequireOpen();
            Navigator.Go(new ChatDestination("default", "s-budget", "Quarterly budget"));
            await HereAsync(shell, url, "s-budget", HereNested, "default", HereNestedHome);
            await shot("new-chat-here-project");
        }, () => MoveAsync(HereNestedHome)); // restore once, before the gateway closes

        // A chat in no project of its bot's: Home, no folder.
        lifetime.RequireOpen();
        Navigator.Go(new ChatDestination("research", "s-recipes", "Bread recipes"));
        await HereAsync(shell, url, "s-recipes", "/home/hermes/app", "research", null);
        await shot("new-chat-here-home");

        // The bot's own chat: no list row, its live folder decides.
        lifetime.RequireOpen();
        Navigator.Go(new BotChatDestination(hub.Bots.Bot("deploys")!.Model));
        var botChat = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId != null && !p.StoredId.StartsWith("s-new-") ? p : null,
            "Deploys's own chat");
        lifetime.RequireOpen();
        await HereAsync(shell, url, botChat.StoredId!, "/home/hermes/app", "deploys", "/home/hermes/app");
        await shot("new-chat-here-bot");

        // Off: a place's page, then nothing open after Close Chat. No chat is made.
        lifetime.RequireOpen();
        Navigator.Open("sessions");
        await Until(() => shell.KeyState().Pane == OpenPane.Place ? shell : null, "the Sessions page");
        await NothingAsync(shell, url, "the Sessions page");
        lifetime.RequireOpen();
        Navigator.Go(new ChatDestination("research", "s-recipes", "Bread recipes"));
        await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == "s-recipes" ? p : null, "Bread recipes");
        lifetime.RequireOpen();
        shell.CloseChat();
        await Until(() => shell.PaneEmpty ? shell : null, "the pane to empty");
        await NothingAsync(shell, url, "nothing open");
        await shot("new-chat-here");   // No Chat Open: invoking the command made no session.
    }

    /// With `storedId` open and its live folder `liveCwd` known: the shell's New Chat Here makes one `session.create` for
    /// `profile` in `folder` (null: Home), and the new chat opens in the pane, empty.
    private static async Task HereAsync(ShellPage shell, string url, string storedId, string liveCwd, string profile, string? folder)
    {
        var lifetime = App.Window!.Lifetime;
        var page = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == storedId && p.LiveCwd == liveCwd ? p : null,
            $"{storedId} open in {liveCwd}");
        await Until(() => ChatKeys.CanNewChatHere(shell.KeyState()) ? shell : null, $"New Chat Here on in {storedId}");
        var mark = WalkProof.RpcCount(await StandIn(url, "/__fixture/state"));
        lifetime.RequireOpen();
        Destination? went = null;
        void Seen(Destination d) => went ??= d;
        Navigator.Requested += Seen;
        try
        {
            AppLog.Note("automation", "walk new-chat-here: the shell's New Chat Here (in-app, no keys)");
            shell.NewChatHere();
            await Until(() => went != null ? shell : null, "the new chat to open");
        }
        finally { Navigator.Requested -= Seen; }

        string? why = "not read yet";
        var until = DateTime.UtcNow.AddSeconds(10);
        while (why != null && DateTime.UtcNow < until)
        {
            why = NewChatHere.StartedOnce(await StandIn(url, "/__fixture/state"), mark, profile, folder);
            if (why != null) await Task.Delay(200, lifetime.StopToken);
        }
        if (why != null) throw new InvalidOperationException(why);

        if (went is not ChatDestination { Title: "New Chat" } chat || chat.Profile != profile || !chat.StoredId.StartsWith("s-new-"))
            throw new InvalidOperationException($"New Chat Here opened {went}, not a new chat with {profile}");
        var opened = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == chat.StoredId ? p : null, "the new chat in the pane");
        await Task.Delay(500, lifetime.StopToken);
        lifetime.RequireOpen();
        if (opened.MessageCount != 0) throw new InvalidOperationException($"the new chat opened with {opened.MessageCount} messages");
        if (shell.KeyState() is not { Pane: OpenPane.Chat } state || state.StoredId != chat.StoredId || state.Profile != profile)
            throw new InvalidOperationException($"the shell holds {shell.KeyState()}, not the new chat");
        var box = FindIn(opened, "chat.composer");
        AppLog.Note("automation", $"walk new-chat-here: {profile} in {folder ?? "Home"}; the message box has the keyboard: {box != null && FocusedIn() == box}");
    }

    private static async Task NothingAsync(ShellPage shell, string url, string what)
    {
        var lifetime = App.Window!.Lifetime;
        lifetime.RequireOpen();
        if (ChatKeys.CanNewChatHere(shell.KeyState())) throw new InvalidOperationException($"New Chat Here is on with {what}");
        var mark = WalkProof.RpcCount(await StandIn(url, "/__fixture/state"));
        lifetime.RequireOpen();
        shell.NewChatHere();
        await Task.Delay(1000, lifetime.StopToken);
        if (NewChatHere.StartedNothing(await StandIn(url, "/__fixture/state"), mark) is { } why) throw new InvalidOperationException($"{why} ({what})");
    }
}
