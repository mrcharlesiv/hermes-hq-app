using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Composer;
using HermesHQ.Pages;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-DELIVERY-WALK] chat-delivery: the send-delivery cards drawn for real, over the real wire against
/// windows/ci/fixtures/performance-fixture-gateway.py (windows.yml's "delivery" extra; build47-fixture-gateway.py's plans
/// refuse prompt.submit with JSON-RPC error data {reason}, and serve the add-on's sessions/working ledger), backed by
/// Hermes.Core DeliveryWalkProof. The words go in the message box (its Text) and every button is invoked through its
/// automation peer: no OS input. Each shot comes after its UIA element is found with the Mac's exact words (93f984bb1
/// App/Chat/ChatRow.swift, ChatCells.swift, ChatViewController.swift, LiveChatSession.swift OwnerWait,
/// TurnErrorCopy.swift chatLocked, ExternalTurn):
///   delivery-unconfirmed   A send answered 4090 SESSION_OWNER_UNCONFIRMED: your bubble with "Delivery Unconfirmed · Check"
///                          (chat.delivery-check); the stand-in saw one try.
///   delivery-check-notice  Check invoked; the stand-in's history hasn't the row: "… doesn’t have this message yet." (no resend).
///   owner-wait             SESSION_NOT_OWNED (opened by cli) four times: "Your message is waiting" (chat.ownerWait) with
///                          Cancel Message, the header "Waiting for a background task…".
///   chat-delivery          (the walk's own) then it sends once and the stand-in's reply is under it.
///   chat-locked            4001 profile_mismatch: the problem card (chat.problem) with Continue in New Chat then Copy, the
///                          words back in the box, one try. (Not pressed: the stand-in makes no new chat, session.create.)
///   external-working       Sam's chat, whose stored history ends on a prompt another app wrote just now while the ledger
///                          names the chat: the header's "Working…"; the ledger going idle ends it.
internal static partial class ProofWalks
{
    private static void RegisterDeliveryWalks() =>
        Automation.NamedWalks["chat-delivery"] = ChatDeliveryAsync;   // DeliveryWalkProof.Walk

    private static async Task ChatDeliveryAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        // The add-on answers from the start (nothing runs), so the owner wait's watch never learns "no add-on".
        await DeliveryPostAsync(url, DeliveryWalkProof.WorkingPath, DeliveryWalkProof.IdleBody());
        // The stand-in serves the add-on's ledger from now on. The sign-in's first chat open asked before this and heard
        // 404 (CI 45141338140, 09:04:19), which the app rightly believes for ExternalTurn.MissingRecheck (600 s, as the
        // Mac's askLedger); a fresh app would ask again, so the walk starts from that.
        Hermes.Core.Chat.ExternalTurn.ForgetMissingLedgers();
        var hub = await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Bots.Bot(DeliveryWalkProof.Bot) != null
            && h.Bots.Bot(DeliveryWalkProof.ExternalBot) != null ? h : null, "the roster with Hermes and Sam", 30);
        var chat = await DeliveryChatAsync(hub, DeliveryWalkProof.Bot);
        var session = ComposerController.For(chat)!.Composer.Session;

        // 1. Delivery unconfirmed: the bubble's line, a button with the Mac's words.
        await DeliveryPostAsync(url, DeliveryWalkProof.PlanPath, DeliveryWalkProof.UnconfirmedPlan());
        var mark = DeliveryWalkProof.Mark(await StandIn(url, DeliveryWalkProof.StandIn));
        await SendFromBoxAsync(chat, DeliveryWalkProof.UnconfirmedText);
        await UntilChecked(() => DeliveryWalkProof.Unconfirmed(session.Messages), "the note marked unconfirmed");
        await UntilDeliveryWire(url, s => DeliveryWalkProof.UnconfirmedWire(s, mark), "the note's one try");
        LastIntoView(chat);
        var check = await Until(() => FindIn(chat, DeliveryWalkProof.CheckId), "the Check line under the note");
        if (DeliveryWalkProof.CheckButton(Id(check), AutomationProperties.GetName(check)) is { } a) throw new InvalidOperationException(a);
        if (check is not HyperlinkButton { Content: TextBlock { Text: DeliveryWalkProof.CheckLine } })
            throw new InvalidOperationException("check: the line isn't a button drawn with the Mac's words");
        AppLog.Note("automation", $"walk chat-delivery: \"{DeliveryWalkProof.CheckLine}\" under the note ({DeliveryWalkProof.Describe(await StandIn(url, DeliveryWalkProof.StandIn), mark)})");
        await Task.Delay(400);
        await shot("delivery-unconfirmed");   // DeliveryWalkProof.UnconfirmedShot

        // 2. Check, through the line's own peer: the stand-in's history hasn't it, so the notice (3 s) says so.
        Invoke(check);
        var notice = await Until(() => FindIn(chat, "chat.notice") is { } n && AutomationProperties.GetName(n) is { Length: > 0 } words
            && words != Hermes.Core.Chat.ChatSession.CheckingDeliveryWords ? n : null, "Check's notice");
        if (DeliveryWalkProof.Notice(AutomationProperties.GetName(notice)) is { } b) throw new InvalidOperationException(b);
        if ((FindIn(notice, "chat.notice.text") as TextBlock)?.Text != DeliveryWalkProof.NotThere)
            throw new InvalidOperationException("notice: its words aren't drawn");
        await shot("delivery-check-notice");   // DeliveryWalkProof.CheckNoticeShot
        if (DeliveryWalkProof.Unconfirmed(session.Messages) is { } c) throw new InvalidOperationException("after Check: " + c);
        await Task.Delay(500);
        if (DeliveryWalkProof.UnconfirmedWire(await StandIn(url, DeliveryWalkProof.StandIn), mark) is { } d) throw new InvalidOperationException("after Check: " + d);

        // 3. The chat held by a one-shot run: the waiting card and the header while it waits, then it sends.
        await DeliveryPostAsync(url, DeliveryWalkProof.PlanPath, DeliveryWalkProof.OwnerWaitPlan());
        mark = DeliveryWalkProof.Mark(await StandIn(url, DeliveryWalkProof.StandIn));
        await SendFromBoxAsync(chat, DeliveryWalkProof.OwnerText);
        var wait = await Until(() => FindIn(chat, DeliveryWalkProof.OwnerWaitId), "Your message is waiting");
        var cancel = FindIn(wait, DeliveryWalkProof.OwnerWaitId + ".action") as Button;
        if (DeliveryWalkProof.OwnerWaitCard((FindIn(wait, DeliveryWalkProof.OwnerWaitId + ".title") as TextBlock)?.Text,
                (FindIn(wait, DeliveryWalkProof.OwnerWaitId + ".body") as TextBlock)?.Text, cancel?.Content as string) is { } e)
            throw new InvalidOperationException(e);
        var waiting = HeaderStatus(chat);
        if (waiting != DeliveryWalkProof.OwnerWaitStatus) throw new InvalidOperationException($"owner wait: the header says \"{waiting}\"");
        AppLog.Note("automation", $"walk chat-delivery: \"{DeliveryWalkProof.OwnerWaitTitle}\" with {DeliveryWalkProof.OwnerWaitCancel}, header \"{waiting}\"");
        await Task.Delay(300);
        await shot("owner-wait");   // DeliveryWalkProof.OwnerWaitShot
        await UntilChecked(() => FindIn(chat, DeliveryWalkProof.OwnerWaitId) != null ? "the waiting card still shows"
            : session.Busy ? "the reply still runs" : DeliveryWalkProof.OwnerSent(session.Messages), "the waiting message sent and answered", 30);
        await UntilDeliveryWire(url, s => DeliveryWalkProof.OwnerWire(s, mark), "the refusals then one send");
        AppLog.Note("automation", $"walk chat-delivery: sent after the wait ({DeliveryWalkProof.Describe(await StandIn(url, DeliveryWalkProof.StandIn), mark)})");
        // [WIN-OWN-TURN-ROWS] The reply is in and nothing runs: the bot's row says Working… no more (CI 45141338140 kept an
        // earlier gateway's turn on it).
        await UntilChecked(() => hub.Bots.Bot(DeliveryWalkProof.Bot)?.IsWorking == true ? "the bot row still says Working… with nothing running" : null,
            "the bot row's Working… to go", 15);
        LastIntoView(chat);
        await Task.Delay(400);
        await shot("chat-delivery");   // DeliveryWalkProof.FinalShot

        // 4. A locked chat (4001 profile_mismatch): the problem card, the words back in the box, one try.
        await DeliveryPostAsync(url, DeliveryWalkProof.PlanPath, DeliveryWalkProof.LockedPlan());
        mark = DeliveryWalkProof.Mark(await StandIn(url, DeliveryWalkProof.StandIn));
        var box = (TextBox)Need(chat, "chat.composer");
        box.Text = DeliveryWalkProof.LockedText;
        box.SelectionStart = box.Text.Length;
        Invoke(await Until(() => FindIn(chat, "chat.send") is Control { IsHitTestVisible: true, IsEnabled: true } s ? s : null, "the Send button, on"));
        var problem = await Until(() => FindIn(chat, DeliveryWalkProof.LockedId), "the locked chat's card");
        await UntilChecked(() => DeliveryWalkProof.LockedCard((FindIn(problem, DeliveryWalkProof.LockedId + ".title") as TextBlock)?.Text,
            (FindIn(problem, DeliveryWalkProof.LockedId + ".body") as TextBlock)?.Text, box.Text), "the locked chat's card and the words back");
        // [WIN-CHAT-LOCKED-ACTIONS] Its buttons as drawn, in order: Continue in New Chat (chat.problem.action), then Copy.
        var copy = FindIn(problem, DeliveryWalkProof.LockedId + ".copy") as Button;
        var shownButtons = (copy?.Parent as Panel)?.Children.OfType<Button>().Select(b => b.Content as string).ToList() ?? [];
        if (DeliveryWalkProof.LockedButtons(shownButtons) is { } lb) throw new InvalidOperationException(lb);
        if ((FindIn(problem, DeliveryWalkProof.LockedId + ".action") as Button)?.Content as string != DeliveryWalkProof.LockedAction)
            throw new InvalidOperationException($"locked: {DeliveryWalkProof.LockedId}.action isn't \"{DeliveryWalkProof.LockedAction}\"");
        if (FindIn(chat, Hermes.Core.Chat.ComposerNotices.SendFailureId) != null) throw new InvalidOperationException("locked: Couldn't Send shows beside the problem card");
        await UntilDeliveryWire(url, s => DeliveryWalkProof.LockedWire(s, mark), "the locked chat's one try");
        await Task.Delay(400);
        await shot("chat-locked");   // DeliveryWalkProof.LockedShot
        box.Text = "";

        // 5. Another app's turn in Sam's chat: its stored history ends on a prompt written just now, and the ledger names it.
        var sam = hub.Bots.Bot(DeliveryWalkProof.ExternalBot)!;
        var samId = await client.BotChatIdAsync(sam.Model);
        await DeliveryPostAsync(url, DeliveryWalkProof.ExternalPath, DeliveryWalkProof.ExternalBody());
        await DeliveryPostAsync(url, DeliveryWalkProof.WorkingPath, DeliveryWalkProof.WorkingBody(samId));
        try
        {
            var other = await DeliveryChatAsync(hub, DeliveryWalkProof.ExternalBot);
            var otherSession = ComposerController.For(other)!.Composer.Session;
            await UntilChecked(() => DeliveryWalkProof.Header(HeaderStatus(other)), "the header's Working…", 20);
            if (otherSession.ExternalWork != Hermes.Core.Chat.ExternalTurn.Source.Ledger)
                throw new InvalidOperationException($"external: the watch's source is {otherSession.ExternalWork}, not the ledger");
            if (!otherSession.Messages.Any(m => m.Text == DeliveryWalkProof.ExternalText)) throw new InvalidOperationException("external: the other app's prompt isn't shown");
            AppLog.Note("automation", "walk chat-delivery: Sam's header says Working… (the ledger names the chat)");
            LastIntoView(other);
            await Task.Delay(400);
            await shot("external-working");   // DeliveryWalkProof.WorkingShot

            // The other app's turn ends: the ledger idles, its answer is stored, and Working… goes (the watch reads every 3 s).
            await DeliveryPostAsync(url, DeliveryWalkProof.WorkingPath, DeliveryWalkProof.IdleBody());
            await DeliveryPostAsync(url, DeliveryWalkProof.FinishPath, """{"profile":"sam","text":"Synthetic answer to the other app."}""");
            await UntilChecked(() => HeaderStatus(other) == DeliveryWalkProof.Working ? "the header still says Working…" : null, "Working… to end", 15);
        }
        finally
        {
            try { await DeliveryPostAsync(url, DeliveryWalkProof.WorkingPath, DeliveryWalkProof.IdleBody()); }
            catch (Exception x) { AppLog.Note("automation", $"walk chat-delivery: reset failed ({x.GetType().Name})"); }
        }
    }

    /// The bot's own chat, open with its message box, its history read and nothing running.
    private static async Task<ChatPage> DeliveryChatAsync(ListsHub hub, string profile)
    {
        Navigator.Go(new BotChatDestination(hub.Bots.Bot(profile)!.Model));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } p && !p.IsBusy && p.MessageCount > 0
            && ComposerController.For(p) is { } cc && cc.Composer.Session.Profile == profile && FindIn(p, "chat.composer") != null ? p : null,
            $"{profile}'s chat", 20);
        await Task.Delay(1500);   // the chat's own binding (session.resume) settles
        return chat;
    }

    /// The chat header's status line (ChatPage's StatusText, under the title). By name: the Mac's status line
    /// (93f984bb1 App/Chat/ChatChrome.swift ChatStatusPill) carries no accessibility identifier to copy, only its words
    /// as its label (`chat.status.steps` is the Show Steps tap area over it, not the line).
    private static string? HeaderStatus(ChatPage chat) => (chat.FindName("StatusText") as TextBlock)?.Text;

    private static void LastIntoView(ChatPage chat)
    {
        if (FindIn(chat, "chat.transcript") is ListView list && (list.ItemsSource as IEnumerable<object>)?.OfType<MessageItem>().LastOrDefault() is { } last)
            list.ScrollIntoView(last, ScrollIntoViewAlignment.Leading);
    }

    private static async Task DeliveryPostAsync(string url, string path, string body)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        (await http.PostAsync(url.TrimEnd('/') + path, new StringContent(body, System.Text.Encoding.UTF8, "application/json"))).EnsureSuccessStatusCode();
    }

    /// Polls `check` until it passes (null), for at least 10 s; then fails with what it last said.
    private static async Task UntilChecked(Func<string?> check, string what, int seconds = 15)
    {
        var until = DateTime.UtcNow.AddSeconds(Math.Max(10, seconds));
        string? last;
        while ((last = check()) != null && DateTime.UtcNow < until) await Task.Delay(100);
        if (last != null) throw new InvalidOperationException($"{what}: {last}");
    }

    /// Polls the stand-in's ledger until `check` passes (null), for at least 10 s.
    private static async Task UntilDeliveryWire(string url, Func<System.Text.Json.Nodes.JsonNode, string?> check, string what)
    {
        var until = DateTime.UtcNow.AddSeconds(15);
        string? last;
        do
        {
            last = check(await StandIn(url, DeliveryWalkProof.StandIn));
            if (last == null) return;
            await Task.Delay(250);
        } while (DateTime.UtcNow < until);
        throw new InvalidOperationException($"{what}: {last}");
    }
}
