using System.Runtime.CompilerServices;
using Hermes.Core.Activity;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Transcripts;
using HermesHQ.Controls;
using HermesHQ.Services;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Transcript;

/// How the transcript reads and what sits around it (PARITY.md › Chat: tool-call styles and the step sheet; the
/// subagents / goal shelf; Rename and Share; the inspector's Info, Steps, Files and Helpers; "Couldn’t Send"; the
/// earlier-messages Try Again). The bubbles themselves are Controls/MessageView.
public static class TranscriptFeature
{
    /// Each open chat's reasoning timer ("Thought for 7s"), kept with its session.
    private static readonly ConditionalWeakTable<ChatSession, ReasoningTimes> Clocks = new();
    /// Each open chat page's thinking row (the automation run reads its words).
    private static readonly ConditionalWeakTable<Page, ThinkingRowView> Thinking = new();

    /// The words the chat page's thinking row shows now; null while it isn't drawn.
    public static string? ThinkingWords(Page page) => Thinking.TryGetValue(page, out var row) ? row.Shown : null;

    private sealed class ReasoningTimes
    {
        public readonly ReasoningClock Clock = new();
        /// The last answer per reply, so an unchanged one is the same object (the bubble isn't redrawn for nothing).
        public readonly Dictionary<string, IReadOnlyDictionary<int, double>> Shown = [];
    }

    public static void Register()
    {
        ChatDisplaySettings.Store = FilePreferences.Shared;
        ChatViewModel.ReasoningSeconds = (session, m) =>
        {
            if (!Clocks.TryGetValue(session, out var times)) return null;
            lock (times)
            {
                var now = times.Clock.Seconds(m.Id);
                if (now.Count == 0) return null;
                if (times.Shown.TryGetValue(m.Id, out var before) && before.Count == now.Count
                    && before.All(kv => now.TryGetValue(kv.Key, out var v) && v == kv.Value)) return before;
                times.Shown[m.Id] = now;
                return now;
            }
        };
        ChatExtensions.OnOpen.Add(Open);
    }

    private static void Open(ChatContext ctx)
    {
        var session = ctx.Session;
        var ui = ctx.Page.DispatcherQueue;
        var times = Clocks.GetValue(session, _ => new ReasoningTimes());
        var store = new ActivityStore(session.Profile, session.RuntimeId, session.StoredId);
        var shelf = new ActivityShelf(session, store);
        var inspector = new ChatInspector(session, () => { lock (store) return store.Snapshot; });
        ctx.Shelf.Children.Add(shelf.View);
        HermesHQ.Features.Bots.ChatRowsWorking.Watch(ctx);   // [WIN-EXTERNAL-SURFACES] Working… on the Bots/Sessions rows
        ctx.Inspector.Content = inspector.View;
        // [WIN-THINKING-STEP] The thinking row names the running step; a click shows the turn's steps.
        var thinking = ThinkingRowView.Attach(ctx, () =>
        {
            ctx.ShowInspector(true);
            inspector.Show(ChatInspector.Tab.Steps);
        });
        Thinking.AddOrUpdate(ctx.Page, thinking);

        // "Couldn’t Send" (§6.3): one card over ChatSession.SendFailure, for typed and memo refusals alike (the latest
        // wins); Try Again sends what is in the box.
        var sendCard = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        ctx.Shelf.Children.Add(sendCard);
        // [WIN-SEND-REFUSE-WITHDRAW] A refused typed send's bubble is gone (ChatSession.RefuseSend); its words come back
        // here (AppModel's `onDraftReturned`): into an empty box, else before what was typed meanwhile, never over it.
        // The reason is the Couldn’t Send card's, so no notice (a refusal always sets SendFailure first).
        void OnDraftReturned(string text, string reason) => ui.TryEnqueue(() =>
        {
            var merged = ChatSession.ReturnedDraft(ctx.Composer.Text, text);
            if (merged != ctx.Composer.Text) { ctx.Composer.Text = merged; ctx.Composer.SelectionStart = merged.Length; }
            ctx.RefreshComposer();
        });
        session.DraftReturned += OnDraftReturned;
        (string Body, string? Copy)? shownFailure = null;
        // [WIN-OWNER-WAIT] "Your message is waiting" (ChatSession.OwnerWaitNotice: ✕ hides it, Cancel Message takes the
        // message back like Stop) and [locked-chat] the problem card (ChatSession.SessionProblem), both at the composer.
        var waitCard = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        ctx.Shelf.Children.Add(waitCard);
        var problemCard = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        ctx.Shelf.Children.Add(problemCard);
        OwnerWait? shownWait = null;
        SessionProblem? shownProblem = null;
        // The read of earlier messages failed (§4.2).
        var earlier = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        ctx.Shelf.Children.Insert(0, earlier);

        var pending = 0;
        var closed = false;
        void Update()
        {
            if (closed || AppShutdown.Stopping || Interlocked.Exchange(ref pending, 1) == 1) return;
            ui.TryEnqueue(() =>
            {
                Interlocked.Exchange(ref pending, 0);
                if (closed || AppShutdown.Stopping) return;
                shelf.Refresh();
                if (ctx.IsInspectorShown()) inspector.Refresh();
                var failure = session.SendFailure;
                (string, string?)? now = failure == null ? null : (failure.Body, failure.CopyText);
                if (now != shownFailure)
                {
                    shownFailure = now;
                    sendCard.Content = failure == null ? null : SendFailureCard(failure, ctx);
                }
                var wait = session.OwnerWaitNotice;
                if (wait != shownWait)
                {
                    shownWait = wait;
                    waitCard.Content = wait == null ? null : NoticeCard(ComposerNotices.OwnerWaitId, OwnerWait.CardTitle, wait.CardBody,
                        session.DismissOwnerWait, OwnerWait.CancelTitle, () => _ = session.CancelOwnerWaitAsync(), null);
                }
                var problem = session.SessionProblem;
                if (problem != shownProblem)
                {
                    shownProblem = problem;
                    // [WIN-CHAT-LOCKED-ACTIONS] The Mac's problem card: its primary, then Copy (`problemCard.onPrimary`).
                    // [WIN-COMPOSER-CARD-IDS] Choose a Model opens this chat's model chooser (`presentModelSheet`, the
                    // error card's own way there); Try Again resumes and reads again (`retryAfterProblem`).
                    problemCard.Content = problem == null ? null : NoticeCard(ComposerNotices.ProblemId, problem.Title, problem.Body,
                        session.DismissSessionProblem, ComposerNotices.ActionTitle(problem.Primary), problem.Primary switch
                        {
                            SessionProblemPrimary.NewChat => () => ContinueInNewChat(ctx, problemCard),
                            SessionProblemPrimary.ChooseModel => () => MessageView.RequestChooseModel(session),
                            _ => () => _ = session.RetryAfterProblemAsync(),
                        }, problem.CopyText);
                }
                earlier.Content = session.OlderFailed ? EarlierCard(session) : null;
            });
        }

        void OnEvent(Hermes.Core.Rpc.RpcEvent e)
        {
            lock (store)
            {
                if (store.RuntimeId == null && session.RuntimeId is { } rid) store.Bind(rid, session.StoredId, session.Profile);
                store.Apply(e);
            }
            lock (times)
            {
                var messages = session.Messages;
                times.Clock.Note(messages.LastOrDefault(m => m.IsStreaming)?.Id, id => messages.LastOrDefault(m => m.Id == id));
            }
            Update();
        }
        void OnChanged() => Update();
        void OnStep(ChatSession s, ChatMessage m, ToolCall? call)
        {
            if (s != session) return;
            ctx.ShowInspector(true);
            inspector.ShowStep(m, call);
        }
        void OnInspectorTrigger() { if (!closed && !AppShutdown.Stopping && ctx.IsInspectorShown()) inspector.Refresh(); }
        session.EventApplied += OnEvent;
        session.Changed += OnChanged;
        ctx.TranscriptChanged += OnInspectorTrigger;
        ChatExtensions.StepRequested += OnStep;

        // ⋯ › Share… (the chat as text) and Rename… (not a bot's own chat).
        var share = new MenuFlyoutItem { Text = MessageMenu.ShareWord, Icon = new FontIcon { Glyph = "" } };
        share.Click += (_, _) =>
        {
            var botName = session.Profile is { Length: > 0 } p && p != "default" ? char.ToUpperInvariant(p[0]) + p[1..] : "Hermes";
            var messages = session.Messages;
            if (!messages.Any(m => m.Role is Role.User or Role.Assistant && m.Text.Trim().Length > 0)) return;
            MessageView.ShareText(MessageMenu.Transcript(messages, botName, session.Title), session.Title);
        };
        ctx.MoreMenu.Items.Add(share);
        if (!ctx.IsBotChat && session.Title != Bot.BotChatTitle)
        {
            var rename = new MenuFlyoutItem { Text = "Rename…", Icon = new FontIcon { Glyph = "" } };
            rename.Click += async (_, _) => await RenameAsync(ctx);
            ctx.MoreMenu.Items.Add(rename);
        }

        ctx.Closed += () =>
        {
            closed = true;
            session.EventApplied -= OnEvent;
            session.Changed -= OnChanged;
            ctx.TranscriptChanged -= OnInspectorTrigger;
            session.DraftReturned -= OnDraftReturned;
            ChatExtensions.StepRequested -= OnStep;
        };
        Update();
    }

    /// [locked-chat] Continue in New Chat (ChatViewController's `.newChat` → `slashHooks.newChat(composer.text)`): the same
    /// bot's new chat, made as Bots › New Chat makes one, opened through the Navigator in this chat's place with the words
    /// in the box in its field; nothing goes to this chat. An unknown bot or no roster opens nothing and says
    /// "Couldn’t open a new chat." (the Mac's announcement); a failed make says why, as /new's does.
    private static void ContinueInNewChat(ChatContext ctx, FrameworkElement card)
    {
        var ui = ctx.Page.DispatcherQueue;
        var root = ctx.Page.XamlRoot;
        var hub = HermesHQ.Features.Bots.ListsHub.Current;
        var words = ctx.Composer.Text;
        var started = hub == null ? null : ComposerNotices.ContinueInNewChat(ctx.Session.Profile, words, p => hub.Bots.Bot(p) != null,
            p => hub.Sessions.NewChatAsync(p),
            o => ui.TryEnqueue(() => Navigator.Go(new ChatDestination(o.Profile, o.StoredId, Hermes.Core.Composer.NewChatCommand.Title, o.Draft))),
            e => ui.TryEnqueue(() =>
            {
                var title = e is Hermes.Core.Bots.BotWriteException { Title.Length: > 0 } w ? w.Title : "Couldn’t Start a New Chat";
                var reason = e is Hermes.Core.Bots.BotWriteException b ? b.Reason : Hermes.Core.Sessions.SessionStore.ReasonOf(e);
                _ = HermesHQ.Features.Bots.Prompts.FailureAsync(root, title, reason, () => { ContinueInNewChat(ctx, card); return Task.CompletedTask; });
            }));
        AppLog.Note("chatui", started == null ? "locked chat: no new chat opened" : $"locked chat: a new chat with the same bot, {words.Trim().Length} chars carried");
        if (started == null)
            Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(card)?.RaiseNotificationEvent(
                Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationKind.Other,
                Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationProcessing.ImportantMostRecent, ComposerNotices.NewChatFailed, "chat.problem.newChat");
    }

    /// Rename Chat: a box with the name, Rename, Cancel (ChatMenus.promptRename). [WIN-CHAT-INTRO] An unnamed chat's
    /// ("New Chat") is Name Chat with its field empty, not "New Chat" to delete first; the empty chat's Name Chat opens it.
    internal static async Task RenameAsync(ChatContext ctx)
    {
        var session = ctx.Session;
        var unnamed = Hermes.Core.Chat.ChatIntro.IsUnnamed(session.Title);
        var box = new TextBox { Text = unnamed ? "" : session.Title, MinWidth = 320 };
        var dialog = new ContentDialog
        {
            Title = unnamed ? "Name Chat" : "Rename Chat", Content = box,
            PrimaryButtonText = "Rename", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
            XamlRoot = ctx.Page.XamlRoot,
        };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        if (await SafeDialog.ShowAsync(ctx.Page.XamlRoot, dialog) != ContentDialogResult.Primary || box.Text.Trim().Length == 0) return;
        try { await session.RenameAsync(box.Text); }
        catch (GatewayException x)
        {
            AppLog.Note("chat", $"rename failed: {x.Code}");
            await SafeDialog.ShowAsync(ctx.Page.XamlRoot, new ContentDialog { Title = "Couldn’t Rename Chat", Content = x.Message, CloseButtonText = "OK" });
        }
    }

    /// [WIN-SEND-FAILURE-ONE-CARD] ChatViewController's sendFailureCard: ✕ dismisses it; Try Again sends what is in the
    /// field now as the composer's Send does (the memo draft chip, attachments, the queue); with no words and no
    /// attachments there is nothing to send again and the card just goes.
    private static FrameworkElement SendFailureCard(SendFailure failure, ChatContext ctx) =>
        SendFailureCard(failure, ctx.Session.DismissSendFailure, () =>
        {
            var attachments = Attachments.AttachmentsFeature.CenterFor(ctx.Session.Client).Count(ctx.Session.DraftScope) > 0;
            if (ChatSession.TryAgainSends(ctx.Composer.Text, attachments)) ctx.Submit();
            else ctx.Session.DismissSendFailure();
        });

    /// The "Couldn’t Send" card (ChatNoticeCard over `SendFailure`): title, body, ✕, Try Again, and Copy when the
    /// refusal carries details the body leaves out.
    internal static FrameworkElement SendFailureCard(SendFailure failure, Action close, Action tryAgain)
    {
        var stack = new StackPanel { Spacing = 4 };
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new TextBlock { Text = SendFailure.Title, FontWeight = FontWeights.SemiBold };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(title, ComposerNotices.Part(ComposerNotices.SendFailureId, ComposerNotices.TitlePart));   // [WIN-36] the walk's
        head.Children.Add(title);
        var x = new Button { Content = new FontIcon { Glyph = "", FontSize = 10 }, Padding = new Thickness(6, 4, 6, 4),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(x, "Close");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(x, ComposerNotices.Part(ComposerNotices.SendFailureId, ComposerNotices.ClosePart));
        x.Click += (_, _) => close();
        Grid.SetColumn(x, 1);
        head.Children.Add(x);
        stack.Children.Add(head);
        var body = new TextBlock { Text = failure.Body, TextWrapping = TextWrapping.Wrap, FontSize = 13,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush") };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(body, ComposerNotices.Part(ComposerNotices.SendFailureId, ComposerNotices.BodyPart));
        stack.Children.Add(body);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 4, 0, 0) };
        var again = new Button { Content = "Try Again", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(again, ComposerNotices.Part(ComposerNotices.SendFailureId, ComposerNotices.ActionPart));
        again.Click += (_, _) => tryAgain();
        actions.Children.Add(again);
        if (failure.CopyText is { } details)
        {
            var copy = new Button { Content = "Copy" };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(copy, ComposerNotices.Part(ComposerNotices.SendFailureId, ComposerNotices.CopyPart));
            copy.Click += (_, _) => Insights.Share.Copy(details);
            actions.Children.Add(copy);
        }
        stack.Children.Add(actions);
        var card = Card(stack);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(card, ComposerNotices.SendFailureId);
        return card;
    }

    /// A card at the composer (ChatNoticeCard): title, body, ✕, an optional action and an optional Copy.
    internal static FrameworkElement NoticeCard(string automationId, string titleText, string bodyText, Action close,
        string? actionTitle, Action? action, string? copyText)
    {
        var stack = new StackPanel { Spacing = 4 };
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new TextBlock { Text = titleText, FontWeight = FontWeights.SemiBold };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(title, automationId + ".title");
        head.Children.Add(title);
        var x = new Button { Content = new FontIcon { Glyph = "\uE711", FontSize = 10 }, Padding = new Thickness(6, 4, 6, 4),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(x, "Close");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(x, automationId + ".close");
        x.Click += (_, _) => close();
        Grid.SetColumn(x, 1);
        head.Children.Add(x);
        stack.Children.Add(head);
        var body = new TextBlock { Text = bodyText, TextWrapping = TextWrapping.Wrap, FontSize = 13,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush") };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(body, automationId + ".body");
        stack.Children.Add(body);
        if (actionTitle != null || copyText != null)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 4, 0, 0) };
            if (actionTitle != null && action != null)
            {
                var act = new Button { Content = actionTitle };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(act, automationId + ".action");
                act.Click += (_, _) => action();
                actions.Children.Add(act);
            }
            if (copyText != null)
            {
                var copy = new Button { Content = "Copy" };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(copy, automationId + ".copy");
                copy.Click += (_, _) => Insights.Share.Copy(copyText);
                actions.Children.Add(copy);
            }
            stack.Children.Add(actions);
        }
        var card = Card(stack);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(card, automationId);
        return card;
    }

    private static FrameworkElement EarlierCard(ChatSession session)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
        row.Children.Add(new TextBlock { Text = $"Couldn’t load earlier messages from {TranscriptWords.HostPhrase}.", FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center });
        var retry = new HyperlinkButton { Content = "Try Again", FontSize = 12 };
        retry.Click += async (_, _) => { try { await session.LoadOlderAsync(); } catch (GatewayException) { } };
        row.Children.Add(retry);
        return Card(row);
    }

    private static Border Card(UIElement child) => new()
    {
        Child = child, Padding = new Thickness(12, 8, 12, 8), CornerRadius = new CornerRadius(10),
        Background = ThemeBrushes.Get("HQPromptCardBrush"),
        BorderBrush = ThemeBrushes.Get("HQPromptEdgeBrush"), BorderThickness = new Thickness(1),
    };
}
