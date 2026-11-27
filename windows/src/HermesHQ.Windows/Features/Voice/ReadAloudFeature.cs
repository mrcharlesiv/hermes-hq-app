using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Settings;
using Hermes.Core.Voice;
using HermesHQ.Features.Transcript;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Voice;

/// Read Aloud on a reply and Read Replies Aloud (docs/spec/3x-talk.md §7; App/Chat/Voice/ReadAloudCenter.swift and
/// ChatReadAloudHost.swift at 93f984bb1). The message menu's Read Aloud reads that reply with the PC's own voice and
/// reads Stop Reading while it does; another reply takes over; leaving the chat or sending a message stops it; a failure
/// shows “Couldn’t Read Aloud”. With Settings › Voice › Read Replies Aloud on, a reply that completes in the chat on
/// screen is read (never history). Esc stops a running reply, as on the Mac; it does not stop a reading.
/// [WIN-62] The ⋯ menu's Read Replies Aloud row (its tick the switch) says “Read Replies Aloud is on” / “… is off” as it
/// is switched; while it is on, a quiet speaker sits just before the ⋯, named “Read Replies Aloud is on”, whose menu
/// (“Replies are read aloud”) has Stop Reading Replies Aloud (ChatReadAloudHost.swift `repliesItem` / `saySwitch` /
/// `switchChanged`, ChatViewController.swift `makeReadAloudButton`). Every open chat follows a change made anywhere.
public static class ReadAloudFeature
{
    /// One reading at a time, app-wide (the Mac's `ReadAloudCenter.shared`).
    public static ReadAloudCenter Center { get; } = new(new WindowsReadAloudVoice())
    {
        Reachable = () => AppState.Client != null,
        OnFailure = (scope, reason) => Host(scope)?.Failed(reason),
    };

    private static readonly List<ChatHost> Hosts = [];

    public static void Register()
    {
        ChatExtensions.OnOpen.Add(ctx =>
        {
            // A bot's chat (a group room's menu has no Read Aloud: \"Read Aloud joins with voice\").
            if (ctx.Page is not ChatPage) return;
            var host = new ChatHost(ctx);
            lock (Hosts) Hosts.Add(host);
            ctx.Closed += () =>
            {
                lock (Hosts) Hosts.Remove(host);
                host.Left();
            };
        });
    }

    private static ChatHost? Host(string scope) { lock (Hosts) return Hosts.FirstOrDefault(h => h.Scope == scope); }
    private static ChatHost? Host(ChatSession session) { lock (Hosts) return Hosts.FirstOrDefault(h => h.Session == session); }

    /// The hold menu's tile for one reply: null where Read Aloud isn't offered (ChatVoiceHost.talkIsReading).
    public static bool? IsReading(ChatSession session, string messageId) =>
        Host(session) == null ? null : Center.IsReading(messageId);

    /// The menu's Read Aloud / Stop Reading (ChatReadAloudHost.toggle(messageId:)).
    public static void Toggle(ChatSession session, string messageId) => Host(session)?.Toggle(messageId);

    /// The reading's state as the walk names it.
    public static string StateName => Center.State.Phase.ToString().ToLowerInvariant();

    private static bool SwitchOn => VoicePrefs.ReadsRepliesAloud(FilePreferences.Shared);

    /// [WIN-62] The voice was handed a reply by Read Replies Aloud: (message id, the words). The walk counts them.
    internal static event Action<string, string>? RepliesRead;

    /// One open chat (ChatReadAloudHost).
    private sealed class ChatHost
    {
        private readonly ChatContext _ctx;
        private readonly DispatcherQueue _queue;
        private readonly ReadRepliesWatch _watch = new();
        private readonly HashSet<string> _yours;
        private readonly ToggleMenuFlyoutItem _row;
        private readonly Button _speaker;
        public string Scope { get; } = Guid.NewGuid().ToString("N");
        public ChatSession Session => _ctx.Session;

        public ChatHost(ChatContext ctx)
        {
            _ctx = ctx;
            _queue = DispatcherQueue.GetForCurrentThread();
            var messages = ctx.Session.Messages;
            _yours = [.. messages.Where(m => m.Role == Role.User).Select(m => m.Id)];
            _watch.Appeared(messages, ctx.Session.Busy);
            ctx.Session.Changed += OnSessionChanged;
            Center.Changed += OnCenterChanged;
            _row = AddMenuRow(ctx.MoreMenu);
            _speaker = AddSpeaker(ctx.HeaderTrailing);
            VoicePrefs.ReadRepliesChanged += OnSwitchChanged;
            ShowSwitch();
        }

        // ---------------------------------------------------------------- [WIN-62] the ⋯ row and the header's speaker

        /// The ⋯ row in the Mac's section after the chat's own rows (Model…) and before its tools (Prompts…).
        private ToggleMenuFlyoutItem AddMenuRow(MenuFlyout menu)
        {
            var row = new ToggleMenuFlyoutItem { Text = ReadRepliesAloud.MenuTitle, Icon = new FontIcon { Glyph = "\uE995" } };
            AutomationProperties.SetAutomationId(row, ReadRepliesAloud.MenuId);
            row.Click += (_, _) => Say(ReadRepliesAloud.Toggle(FilePreferences.Shared));
            var titles = menu.Items.Select(i => i is MenuFlyoutSeparator ? null : (i as MenuFlyoutItem)?.Text ?? (i as MenuFlyoutSubItem)?.Text ?? "").ToList();
            var place = ReadRepliesAloud.Place(titles, Hermes.Core.Composer.PromptLibrary.Title);
            var at = place.Index;
            if (place.SeparatorBefore) menu.Items.Insert(at++, new MenuFlyoutSeparator());
            menu.Items.Insert(at++, row);
            if (place.SeparatorAfter) menu.Items.Insert(at, new MenuFlyoutSeparator());
            // The tick is read again as the menu opens (the switch may have changed in Settings or another chat).
            menu.Opening += (_, _) => row.IsChecked = SwitchOn;
            return row;
        }

        /// The quiet speaker while the switch is on; its menu says what it is and turns it off.
        private Button AddSpeaker(StackPanel header)
        {
            var stop = new MenuFlyoutItem { Text = ReadRepliesAloud.StopTitle, Icon = new FontIcon { Glyph = "\uE74F" } };
            AutomationProperties.SetAutomationId(stop, ReadRepliesAloud.StopId);
            stop.Click += (_, _) => Say(ReadRepliesAloud.TurnOff(FilePreferences.Shared));
            // The Mac's menu title: words, not a choice.
            var title = new MenuFlyoutItem { Text = ReadRepliesAloud.IndicatorTitle, IsEnabled = false };
            var flyout = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
            flyout.Items.Add(title);
            flyout.Items.Add(stop);
            var speaker = new Button
            {
                Content = new FontIcon { Glyph = "\uE995", FontSize = 14 }, Flyout = flyout, Visibility = Visibility.Collapsed,
                Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            };
            AutomationProperties.SetAutomationId(speaker, ReadRepliesAloud.IndicatorId);
            AutomationProperties.SetName(speaker, ReadRepliesAloud.IndicatorName);
            ToolTipService.SetToolTip(speaker, ReadRepliesAloud.IndicatorName);
            header.Children.Add(speaker);
            return speaker;
        }

        /// The chat says what the switch is now (the Mac's menu closes on the click: saySwitch).
        private void Say(string words)
        {
            if (_ctx.Page is ChatPage page) page.ShowNotice(words, ReadRepliesAloud.NoticeDuration);
        }

        private void OnSwitchChanged(Hermes.Core.Transcripts.IPreferences prefs, bool on)
        {
            if (!ReferenceEquals(prefs, FilePreferences.Shared)) return;
            _queue.TryEnqueue(() =>
            {
                // On: the reply that is the newest now is never read; off: nothing waits, and a reply it was reading stops
                // (Read Aloud asked for by hand goes on).
                _watch.SwitchChanged(on, Session.Messages, Session.Busy);
                if (!on && Center.StopReplies(Scope)) AppLog.Note("voice", "read replies aloud: off, the reading stopped");
                ShowSwitch();
            });
        }

        private void ShowSwitch()
        {
            var on = SwitchOn;
            _row.IsChecked = on;
            _speaker.Visibility = ReadRepliesAloud.ShowsIndicator(offered: true, switchOn: on) ? Visibility.Visible : Visibility.Collapsed;
        }

        private bool ReadingHere => Center.State.Phase != ReadAloudPhase.Idle && Center.Scope == Scope;

        private void OnSessionChanged() => _queue.TryEnqueue(SessionChanged);

        private void SessionChanged()
        {
            if (!_watch.IsOnScreen) return;
            var messages = Session.Messages;
            // A message was sent from this chat: whatever is being read stops (ChatReadAloudHost.messageSent). History
            // read in (older pages, the first load) is not a send: only a new message of yours still on its way.
            var sent = false;
            foreach (var m in messages.Where(m => m.Role == Role.User && m.IsPending))
                if (_yours.Add(m.Id)) sent = true;
            if (sent)
            {
                _watch.MessageSent();
                Center.Stop(Scope);
            }
            // The live reply being read became its stored row (another id): the reading follows it, so the row's menu
            // still says Stop Reading.
            if (ReadingHere && Center.State.MessageId is { } reading && !messages.Any(m => m.Id == reading)
                && reading.StartsWith("local-assistant-", StringComparison.Ordinal)
                && SpokenReply.Newest(messages) is { Pending: false } stored)
                Center.Rebind(Scope, reading, stored.MessageId);
            if (_watch.SessionChanged(messages, Session.Busy, SwitchOn, ReadingHere) is { } id) ReadReply(id, messages);
        }

        private void ReadReply(string id, IReadOnlyList<ChatMessage> messages)
        {
            if (messages.LastOrDefault(m => m.Id == id && m.Role == Role.Assistant) is not { } message) return;
            AppLog.Note("voice", "read replies aloud: reading the newest reply");
            var words = SpokenReply.Of(message).Text;
            RepliesRead?.Invoke(id, words);
            Center.Read(id, words, Scope, auto: true);
        }

        private void OnCenterChanged() => _queue.TryEnqueue(() =>
        {
            if (Center.State.Phase != ReadAloudPhase.Idle || !_watch.IsOnScreen) return;
            var messages = Session.Messages;
            if (_watch.ReadingEnded(messages, SwitchOn) is { } id) ReadReply(id, messages);
        });

        public void Toggle(string messageId)
        {
            if (Center.State.MessageId == messageId)
            {
                Center.Stop();
                return;
            }
            if (Session.Messages.LastOrDefault(m => m.Id == messageId && m.Role == Role.Assistant) is not { } message)
            {
                Failed(ReadAloudCenter.NothingToRead);
                return;
            }
            AppLog.Note("voice", "read aloud: started");
            Center.Toggle(messageId, SpokenReply.Of(message).Text, Scope);
        }

        /// Leaving the chat stops its reading (§7.4).
        public void Left()
        {
            _watch.Left();
            Session.Changed -= OnSessionChanged;
            Center.Changed -= OnCenterChanged;
            VoicePrefs.ReadRepliesChanged -= OnSwitchChanged;
            Center.Stop(Scope);
        }

        /// The Mac's FailureAlert: “Couldn’t Read Aloud”, the reason, OK.
        public void Failed(string reason) => _queue.TryEnqueue(async () =>
        {
            if (!_watch.IsOnScreen || _ctx.Page.XamlRoot is not { } root) return;
            AppLog.Note("voice", "read aloud failed");
            if (FailureShown != null) { FailureShown(reason); return; }
            var dialog = new ContentDialog
            {
                Title = ReadAloudCenter.FailureTitle, Content = reason, CloseButtonText = "OK", XamlRoot = root,
                DefaultButton = ContentDialogButton.Close,
            };
            AutomationProperties.SetAutomationId(dialog, "chat.readAloud.failure");
            try { await dialog.ShowAsync(); }
            catch (Exception x) when (x is InvalidOperationException or System.Runtime.InteropServices.COMException) { /* another dialog is open */ }
        });
    }

    /// The walk takes the alert's words instead of a dialog (null: the dialog shows).
    internal static Action<string>? FailureShown { get; set; }
}
