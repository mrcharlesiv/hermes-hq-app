using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Transcript;
using HermesHQ.Pages;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace HermesHQ.Services;

/// [WIN-THINKING-WALK] chat-thinking: the chat's thinking row drawn for real while a turn holds on a step, over the real
/// wire against its own windows/ci/fixtures/settings-gateway.py (windows.yml's "chat-thinking" extra: the turn held on a
/// terminal's `npm test` with /__settings/hold until /__settings/release), backed by Hermes.Core ThinkingWalkProof. The
/// Mac's intent (93f984bb1 UITests/activity/ActivityEndToEndTests.swift test19b, test19d, test19e), with Ivy's chat on
/// screen and At the Bottom (the default):
///   thinking-step        the row (`chat.waiting`) reads "Ivy is running npm test…" in its UI Automation name and words,
///                        not the model, no counter before 10 s; nothing above the reply names the step.
///   (the timer)          held on past 10 s: the name ends "· 0:1…" and the timer is drawn whole beside the words.
///   thinking-steps-open  the row clicked (its automation peer's Invoke: no OS input) opens the inspector on Steps, "1 step",
///                        the held step's row.
///   chat-thinking        (the walk's own) released: the reply "Hi! I'm Ivy." writes and the row goes; once the turn-end
///                        read lands, Steps keeps the finished reply's step ("1 step", "Ran a command" and its command),
///                        as the Mac's inspector reads the stored turn (WIN-STEPS-AFTER-REPLY).
internal static partial class ProofWalks
{
    private static void RegisterThinkingWalks() =>
        Automation.NamedWalks["chat-thinking"] = ThinkingAsync;   // ThinkingWalkProof.Walk

    private static async Task ThinkingAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        if (ThinkingWalkProof.Words() is { } words) throw new InvalidOperationException(words);
        var hub = await Until(() => ListsHub.Current is { } h && h.Bots.HasRoster && h.Bots.Bot(ThinkingWalkProof.Bot) != null ? h : null,
            "the roster with Ivy", 30);
        // At the Bottom, the Mac's default test19e names; the inspector kept on Info, so the click is what opens Steps.
        ChatDisplaySettings.Style = ToolCallStyle.Bottom;
        FilePreferences.Shared.Set(ThinkingWalkProof.InspectorTabKey, ChatInspector.Tab.Info.ToString());

        var chat = await DeliveryChatAsync(hub, ThinkingWalkProof.Bot);
        var chatId = chat.StoredId ?? throw new InvalidOperationException("Ivy's chat has no stored id");
        if (ThinkingWalkProof.Closed(chat.InspectorShown) is { } open) throw new InvalidOperationException(open);
        await DeliveryPostAsync(url, ThinkingWalkProof.HoldPath, ThinkingWalkProof.HoldBody());
        try
        {
            // 1. The turn holds on `npm test`: the row names the step (test19d), the bot not the model (test19b).
            var sent = DateTime.UtcNow;
            await SendFromBoxAsync(chat, ThinkingWalkProof.Text);
            await UntilThinking(url, s => ThinkingWalkProof.Held(s, 1), "the turn holding on its step");
            if (ThinkingWalkProof.Prompt(await StandIn(url, ThinkingWalkProof.StatePath), chatId) is { } prompt)
                throw new InvalidOperationException(prompt);
            await UntilChecked(() => ThinkingRowSays(chat, row => ThinkingWalkProof.Row(row.Name, row.Texts, (DateTime.UtcNow - sent).TotalSeconds)),
                "the thinking row naming the step", 15);
            // At the Bottom nothing above the reply names it as well (test19e).
            if (ThinkingWalkProof.OnlyTheRow(TranscriptTexts(chat)) is { } twice) throw new InvalidOperationException(twice);
            AppLog.Note("automation", $"walk chat-thinking: the row says \"{ThinkingWalkProof.Label}\"");
            await Task.Delay(600);   // the row's fade and the transcript's scroll to its end settle before the picture
            await shot("thinking-step");   // ThinkingWalkProof.StepShot

            // 2. Held past 10 s: the timer beside the words (test19b "· 0:1", test19e the timer whole).
            await UntilChecked(() => ThinkingRowSays(chat, row => ThinkingWalkProof.Timer(row.Name, row.Texts)), "the row's timer", 20);
            AppLog.Note("automation", $"walk chat-thinking: the row says \"{AutomationProperties.GetName(ThinkingRowOf(chat)!)}\"");

            // 3. A click shows every step of the turn (test19e): the inspector opens on Steps with the held step.
            var row = ThinkingRowOf(chat) ?? throw new InvalidOperationException("the thinking row went before its click");
            Invoke(row);
            await UntilChecked(() => InspectorSteps(chat), "the inspector's Steps after the row's click", 10);
            AppLog.Note("automation", $"walk chat-thinking: the click opened Steps with \"{ThinkingWalkProof.StepRowWords()}\"");
            await Task.Delay(400);
            await shot("thinking-steps-open");   // ThinkingWalkProof.StepsShot

            // 4. Released: the step ends, the reply writes and the row goes (test19b/19d/19e).
            var readsBefore = ThinkingWalkProof.Reads(await StandIn(url, ThinkingWalkProof.StatePath), chatId);
            await DeliveryPostAsync(url, ThinkingWalkProof.ReleasePath, ThinkingWalkProof.ReleaseBody());
            await UntilThinking(url, s => ThinkingWalkProof.Held(s, 0), "the held turn to go on");
            await UntilChecked(() => ThinkingWalkProof.Gone(ThinkingRowOf(chat) != null, ThinkingRowOf(chat) is { } r ? AutomationProperties.GetName(r) : null,
                LastReply(chat)), "the reply written and the row gone", 15);
            AppLog.Note("automation", "walk chat-thinking: the reply wrote; the thinking row is gone");

            // 5. [WIN-STEPS-AFTER-REPLY] The turn-end read lands and Steps keeps the finished reply's step (the Mac's
            // `turnSteps(endingAt: nil)` over the stored turn): "1 step", "Ran a command" with its command.
            await UntilThinking(url, s => ThinkingWalkProof.Reads(s, chatId) > readsBefore ? null : "no read of the chat's messages yet",
                "the turn-end read");
            await UntilChecked(() => InspectorStepsKept(chat), "the inspector's Steps after the reply", 10);
            AppLog.Note("automation", $"walk chat-thinking: after the reply Steps keeps \"{ThinkingWalkProof.StepDoneWords()}\"");
        }
        finally
        {
            // Nothing left held: the stand-in's turn goes on whatever happened.
            try { await DeliveryPostAsync(url, ThinkingWalkProof.ReleasePath, ThinkingWalkProof.ReleaseBody()); }
            catch (Exception x) { AppLog.Note("automation", $"walk chat-thinking: release failed ({x.GetType().Name})"); }
        }
        await Task.Delay(400);
        await shot("chat-thinking");   // ThinkingWalkProof.FinalShot
    }

    /// The chat's thinking row (the Mac's `chat.waiting`), when drawn.
    private static FrameworkElement? ThinkingRowOf(ChatPage chat) => FindIn(chat, ThinkingRow.AutomationId);

    /// The thinking row as drawn: its UI Automation name and every word it draws, checked.
    private static string? ThinkingRowSays(ChatPage chat, Func<DrawnRow, string?> check) =>
        check(ThinkingRowOf(chat) is { } row
            ? new DrawnRow(AutomationProperties.GetName(row), [.. Shown(row).OfType<TextBlock>().Select(t => t.Text)])
            : new DrawnRow(null, []));

    /// Every word the transcript's messages draw (not its footer, where the thinking row sits).
    private static List<string> TranscriptTexts(ChatPage chat) =>
        FindIn(chat, "chat.transcript") is ListView list
            ? [.. Shown(list).OfType<ListViewItem>().SelectMany(i => Shown(i).OfType<TextBlock>()).Select(t => t.Text)]
            : [];

    /// The inspector beside the chat, read as drawn: open, its tabs and which is picked, its words and its buttons' names.
    private static string? InspectorSteps(ChatPage chat)
    {
        var panel = chat.FindName("Inspector") as DependencyObject;
        var shown = panel == null ? [] : Shown(panel).ToList();
        var tabs = shown.OfType<ToggleButton>().Where(t => t.Content is string).Select(t => ((string)t.Content, t.IsChecked == true)).ToList();
        var texts = shown.OfType<TextBlock>().Select(t => t.Text).ToList();
        var names = shown.OfType<Button>().Select(b => AutomationProperties.GetName(b) ?? "").Where(n => n.Length > 0).ToList();
        return ThinkingWalkProof.StepsOpen(chat.InspectorShown, tabs, texts, names);
    }

    /// [WIN-STEPS-AFTER-REPLY] The inspector once the reply wrote, read as drawn: still on Steps with the finished step.
    private static string? InspectorStepsKept(ChatPage chat)
    {
        if (!chat.InspectorShown) return "the inspector closed";
        var panel = chat.FindName("Inspector") as DependencyObject;
        var shown = panel == null ? [] : Shown(panel).ToList();
        var tabs = shown.OfType<ToggleButton>().Where(t => t.Content is string).Select(t => ((string)t.Content, t.IsChecked == true)).ToList();
        var texts = shown.OfType<TextBlock>().Select(t => t.Text).ToList();
        var names = shown.OfType<Button>().Select(b => AutomationProperties.GetName(b) ?? "").Where(n => n.Length > 0).ToList();
        return ThinkingWalkProof.StepsKept(tabs, texts, names);
    }

    /// Polls the stand-in's record until `check` passes (null), for at least 10 s.
    private static async Task UntilThinking(string url, Func<System.Text.Json.Nodes.JsonNode, string?> check, string what)
    {
        var until = DateTime.UtcNow.AddSeconds(15);
        string? last;
        do
        {
            last = check(await StandIn(url, ThinkingWalkProof.StatePath));
            if (last == null) return;
            await Task.Delay(250);
        } while (DateTime.UtcNow < until);
        throw new InvalidOperationException($"{what}: {last}");
    }
}
