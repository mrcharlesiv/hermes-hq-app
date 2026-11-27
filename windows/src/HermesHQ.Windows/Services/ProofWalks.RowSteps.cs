using System.Text.Json.Nodes;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-ROWS-STEP-WALK] row-steps: the rows' live step and "Waking up…" drawn for real, over the real wire against its own
/// windows/ci/fixtures/settings-gateway.py (windows.yml's "row-steps" extra: turns held on one step each with
/// /__settings/hold until /__settings/release, and Research's session.resume slowed with /__settings/fail), backed by
/// Hermes.Core RowStepsWalkProof. Words go in the message box (its Text) and Send is invoked through its peer: no OS input.
/// Every check reads the real rows' UI Automation names and drawn words, as the Mac's (93f984bb1 HermesKit/Activity/
/// LiveSteps.swift, ToolNow.swift; App/Bots/BotListModel.swift; BotStore+RowStatus.swift `noteBotOpening`):
///   row-step-bots      Ivy's Bot Chat, left mid-turn, holds on read_file package.json: Ivy's sidebar row says
///                      "Reading package.json…" (its second line and its name).
///   row-step-sessions  Ivy's side chat Trip ideas, left mid-turn, holds on `cd /Users/me/app && npm test`: its Sessions row
///                      says "Running npm test…" (a Bot Chat never shows on Sessions), and Ivy's row keeps its own step.
///   (the release)      Both turns go on and end: neither row says its step or Working… any more.
///   row-waking         Research's chat opens with its resume held 6 s: once it has taken a second, Research's row says
///                      "Waking up…" (and still does after the picture).
///   row-steps          (the walk's own) Research's chat open: its row no longer says it.
internal static partial class ProofWalks
{
    private static void RegisterRowStepsWalks() =>
        Automation.NamedWalks["row-steps"] = RowStepsAsync;   // RowStepsWalkProof.Walk

    private static async Task RowStepsAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var shell = ShellPage.Current ?? throw new InvalidOperationException("the shell isn't showing");
        var url = client.Session.Address.ToString();
        if (RowStepsWalkProof.Lines() is { } words) throw new InvalidOperationException(words);
        await Until(() => Find(SidebarSearch.ToolsAutomationId), "the sidebar");
        if (Find(SidebarSearch.ToolsAutomationId) is not Grid) await FoldAsync(shell, fold: false);   // the open sidebar's rows have a second line
        var hub = await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Bots.Bot(RowStepsWalkProof.Bot) != null
            && h.Bots.Bot(RowStepsWalkProof.WakingBot) != null ? h : null, "the roster with Ivy and Research", 30);

        await DeliveryPostAsync(url, RowStepsWalkProof.HoldPath, RowStepsWalkProof.HoldBody());
        try
        {
            // 1. Ivy's Bot Chat: a turn that holds on reading package.json, then the chat is left.
            var botChat = await DeliveryChatAsync(hub, RowStepsWalkProof.Bot);
            var botChatId = botChat.StoredId ?? throw new InvalidOperationException("Ivy's chat has no stored id");
            await SendFromBoxAsync(botChat, RowStepsWalkProof.BotText);
            await UntilRowSteps(url, s => RowStepsWalkProof.Held(s, 1), "the Bot Chat's turn holding on its step");

            // Ivy's side chat (the stand-in's Trip ideas): a turn that holds on npm test, then that chat is left too.
            var listed = await client.Rpc.RequestAsync("session.list", new JsonObject { ["profile"] = RowStepsWalkProof.Bot }, TimeSpan.FromSeconds(10));
            var sideId = listed["sessions"]?.AsArray().OfType<JsonObject>()
                .FirstOrDefault(s => s["title"]?.GetValue<string>() == RowStepsWalkProof.SideTitle)?["id"]?.GetValue<string>()
                ?? throw new InvalidOperationException($"the stand-in lists no {RowStepsWalkProof.SideTitle}");
            Navigator.Go(new ChatDestination(RowStepsWalkProof.Bot, sideId, RowStepsWalkProof.SideTitle));
            var side = await Until(() => ChatPage.Current is { IsLoaded: true, IsBusy: false } p && p.StoredId == sideId && p.MessageCount > 0
                && FindIn(p, "chat.composer") != null ? p : null, $"{RowStepsWalkProof.SideTitle}'s chat", 20);
            await Task.Delay(1500);   // the chat's own binding (session.resume) settles
            await SendFromBoxAsync(side, RowStepsWalkProof.SideText);
            await UntilRowSteps(url, s => RowStepsWalkProof.Held(s, 2), "both turns holding on their steps");
            if (RowStepsWalkProof.Prompts(await StandIn(url, RowStepsWalkProof.StatePath), botChatId, sideId) is { } sent)
                throw new InvalidOperationException(sent);

            // Sessions: neither chat on screen. Ivy's row names its Bot Chat's step; Trip ideas' row names its own.
            Navigator.Open("sessions");
            await Until(() => shell.WalkState() is { Pane: OpenPane.Place, PlaceId: "sessions" } f ? f : null, "Sessions in the main window", 20);
            await UntilChecked(() => BotRowSays(shell, RowStepsWalkProof.Bot, row => RowStepsWalkProof.BotRow(row.Name, row.Texts,
                RowStepsWalkProof.BotName, RowStepsWalkProof.BotLine)), "Ivy's row naming its step", 20);
            AppLog.Note("automation", $"walk row-steps: Ivy's row says \"{RowStepsWalkProof.BotLine}\"");
            await Task.Delay(400);
            await shot("row-step-bots");   // RowStepsWalkProof.BotsShot

            await UntilChecked(() => SessionRowSays(RowStepsWalkProof.SideTitle, row => RowStepsWalkProof.SessionRow(row.Name, row.Texts,
                RowStepsWalkProof.SideTitle, RowStepsWalkProof.SideLine)), "Trip ideas' Sessions row naming its step", 20);
            // Each chat its own: Ivy's row still says the Bot Chat's step, not the side chat's.
            if (BotRowSays(shell, RowStepsWalkProof.Bot, row => RowStepsWalkProof.BotRow(row.Name, row.Texts, RowStepsWalkProof.BotName,
                    RowStepsWalkProof.BotLine)) is { } own)
                throw new InvalidOperationException("with the side chat's step: " + own);
            AppLog.Note("automation", $"walk row-steps: Trip ideas' Sessions row says \"{RowStepsWalkProof.SideLine}\"");
            await Task.Delay(400);
            await shot("row-step-sessions");   // RowStepsWalkProof.SessionsShot
            await CheckWorkingRingAsync(shell, shot); // same two working rows, with the Appearance switch off and on

            // 2. The turns go on and end: the steps leave both rows, and Working… with them.
            await DeliveryPostAsync(url, RowStepsWalkProof.ReleasePath, RowStepsWalkProof.ReleaseBody());
            await UntilRowSteps(url, s => RowStepsWalkProof.Held(s, 0), "the held turns to go on");
            await UntilChecked(() => BotRowSays(shell, RowStepsWalkProof.Bot, row => RowStepsWalkProof.BotRowSettled(row.Name, row.Texts,
                RowStepsWalkProof.BotName, RowStepsWalkProof.BotLine)), "Ivy's step to leave its row", 20);
            await UntilChecked(() => SessionRowSays(RowStepsWalkProof.SideTitle, row => RowStepsWalkProof.SessionRowSettled(row.Name, row.Texts,
                RowStepsWalkProof.SideTitle, RowStepsWalkProof.SideLine)), "Trip ideas' step to leave its row", 20);
            AppLog.Note("automation", "walk row-steps: both turns ended; neither row names a step");
        }
        finally
        {
            // Nothing left held: the stand-in's turns go on whatever happened.
            try { await DeliveryPostAsync(url, RowStepsWalkProof.ReleasePath, RowStepsWalkProof.ReleaseBody()); }
            catch (Exception x) { AppLog.Note("automation", $"walk row-steps: release failed ({x.GetType().Name})"); }
        }

        // 3. Research's chat opens slowly: "Waking up…" on its row once a second has gone, gone once it is open.
        await DeliveryPostAsync(url, RowStepsWalkProof.FailPath, RowStepsWalkProof.SlowOpenBody());
        var research = hub.Bots.Bot(RowStepsWalkProof.WakingBot)!;
        Navigator.Go(new BotChatDestination(research.Model));
        string? Waking() => BotRowSays(shell, RowStepsWalkProof.WakingBot, row => RowStepsWalkProof.BotRow(row.Name, row.Texts,
            RowStepsWalkProof.WakingName, RowStepsWalkProof.Waking));
        await UntilChecked(Waking, "Research's row saying Waking up…", 10);
        AppLog.Note("automation", $"walk row-steps: Research's row says \"{RowStepsWalkProof.Waking}\"");
        await shot("row-waking");   // RowStepsWalkProof.WakingShot
        // Still waking once the picture is taken, so the picture has it (it is set once and ends once).
        if (Waking() is { } gone) throw new InvalidOperationException("the open settled before the picture was taken: " + gone);
        await UntilChecked(() => BotRowSays(shell, RowStepsWalkProof.WakingBot, row => RowStepsWalkProof.BotRowSettled(row.Name, row.Texts,
            RowStepsWalkProof.WakingName, RowStepsWalkProof.Waking)), "Waking up… to leave Research's row", 20);
        await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId != null && shell.WalkState() is { Profile: RowStepsWalkProof.WakingBot }
            && FindIn(p, "chat.composer") != null ? p : null, "Research's chat open", 20);
        if (RowStepsWalkProof.SlowOpenTaken(await StandIn(url, RowStepsWalkProof.StatePath)) is { } slow) throw new InvalidOperationException(slow);
        AppLog.Note("automation", "walk row-steps: Research's chat open; its row no longer says Waking up…");
        await Task.Delay(400);
        await shot("row-steps");   // RowStepsWalkProof.FinalShot
    }

    /// A row as drawn: its UI Automation name and every word it draws.
    private readonly record struct DrawnRow(string? Name, IReadOnlyList<string> Texts);

    private static DrawnRow Drawn(ListViewItem? item) => item == null ? new(null, [])
        : new(AutomationProperties.GetName(item), [.. Shown(item).OfType<TextBlock>().Select(t => t.Text)]);

    /// The open sidebar's row of that bot, checked as drawn.
    private static string? BotRowSays(ShellPage shell, string profile, Func<DrawnRow, string?> check) =>
        check(Drawn((shell.SidebarList.ItemsSource as IEnumerable<object> ?? []).OfType<ListViewItem>()
            .FirstOrDefault(i => i.Tag is SidebarBot b && b.Bot.Id == profile)));

    /// The Sessions page's row whose name starts with that title, checked as drawn (brought into view first).
    private static string? SessionRowSays(string title, Func<DrawnRow, string?> check)
    {
        if (Shown(Root).OfType<SessionsPage>().FirstOrDefault()?.FindName("SessionList") is not ListView list) return check(new(null, []));
        var item = (list.ItemsSource as IEnumerable<object> ?? []).OfType<ListViewItem>()
            .FirstOrDefault(i => AutomationProperties.GetName(i) is { } name && name.StartsWith(title + ". ", StringComparison.Ordinal));
        if (item != null && !item.IsLoaded) list.ScrollIntoView(item);
        return check(Drawn(item));
    }

    /// Polls the stand-in's record until `check` passes (null), for at least 10 s.
    private static async Task UntilRowSteps(string url, Func<JsonNode, string?> check, string what)
    {
        var until = DateTime.UtcNow.AddSeconds(15);
        string? last;
        do
        {
            last = check(await StandIn(url, RowStepsWalkProof.StatePath));
            if (last == null) return;
            await Task.Delay(250);
        } while (DateTime.UtcNow < until);
        throw new InvalidOperationException($"{what}: {last}");
    }
}
