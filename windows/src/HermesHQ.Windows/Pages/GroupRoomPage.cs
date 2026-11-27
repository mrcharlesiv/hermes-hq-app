using Hermes.Core.Gateways;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;
using HermesHQ.Controls;
using HermesHQ.Features.ChatFind;
using HermesHQ.Features.Composer;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Groups;
using HermesHQ.Services;
using HermesHQ.ViewModels;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;
using Windows.UI.Core;

namespace HermesHQ.Pages;

/// [groups] A group chat on screen (App/Groups/AppModel+Groups.swift `makeRoomScreen`, GroupRoomChrome.swift): the
/// Mac reuses its ChatViewController with the room's session; here the room draws its rows with the chat's own
/// MessageView (each member's reply under its face and name, Hermes.Core.Groups.GroupRoomChrome) and a composer laid
/// out as the chat's. The title wears the group avatar (the first three members); the status line says who is replying.
/// Opening it reads the room (its sidebar row loses the bold and the dot); the composer sends through the account's
/// GroupEngine (Features/Groups/GroupRooms) and its button is the Stop square while a round runs; Esc stops too.
/// [WIN-52] As the Mac's chat screen draws a room: day lines between days, a typing row per member answering at the
/// transcript's newest end (its face, the dots, the words; plain, so no timer), the empty room (the 56 pt group avatar,
/// the name, the members, the hint), a 34 pt group avatar by the title, the room's ⋯ menu (GroupRoomChrome.swift
/// `moreItems`), and Find in Chat over the room's transcript (the chat's own bar, Features/ChatFind).
/// Not in this slice: the reply chip, the paused capsule, the hold menu (and its Mention).
/// ⋯ › Prompts opens the chat's Prompts (Features/Composer/PromptsDialog) on the room's field; a send into a room with no
/// members says Can’t Send with Add Bots… (online, members not fixed) before OK (GroupRoomChrome.swift `explain`).
/// [WIN-59] The @ list above the composer and its keys (GroupRoomPage.Mentions.cs, Hermes.Core.Groups.GroupMentionList).
/// [WIN-57] The typing row's dots brighten in turn (Hermes.Core.Groups.TypingDots: ChatCells.swift's wave, 1.2 s, 0.2 s
/// apart, one shared clock), still at 60 % while Windows' animations are off (the Mac's Reduce Motion); ⋯ › Activity is the
/// Mac's sheet (Features/Groups/GroupActivityDialog).
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class GroupRoomPage : Page
{
    public sealed record Args(string Key);

    public const string TitleId = "room.title";
    public const string AvatarId = "room.avatar";
    public const string TypingId = GroupRoomChrome.TypingId;
    public const string MoreId = "room.more";
    public const string EmptyId = "room.empty";
    public const string NoticeId = "room.notice";

    /// The room on screen, for the automation run (Services/ProofWalks.GroupRoom.cs).
    public static GroupRoomPage? Current { get; private set; }

    private GroupRoomSession? _session;
    private int _dirty;
    private bool _stopping;
    private bool _roomGone;
    private string? _shownAvatarImage;
    private readonly Dictionary<string, (MessageItem Item, MessageView View)> _rows = [];
    private readonly TextBlock _title = new() { FontWeight = FontWeights.Bold, FontSize = 13, CharacterSpacing = 40, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _status = new() { FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Grid _avatar = new() { Width = GroupRoomChrome.TitleAvatarSide, Height = GroupRoomChrome.TitleAvatarSide, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _more = new() { Width = 32, Height = 32, Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    private readonly MenuFlyout _moreMenu = new();
    /// [WIN-GROUP-EMPTY-FIT] The transcript's room the empty room keeps to (`layoutEmpty(in: transcriptRoom)`): it cuts
    /// the column off at its edges when even the name is too tall, so it is never drawn under the composer.
    private readonly Grid _emptyRoom = new() { Visibility = Visibility.Collapsed, IsHitTestVisible = false };
    private readonly StackPanel _empty = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Spacing = 0, IsHitTestVisible = false };
    private readonly Grid _emptyAvatar = new() { Width = RoomEmptyFit.AvatarSide, Height = RoomEmptyFit.AvatarSide, HorizontalAlignment = HorizontalAlignment.Center };
    /// The room, image and faces the empty room's avatar was drawn for: drawn again when any of them changes.
    private string? _emptyAvatarKey;
    private readonly TextBlock _emptyName = new() { FontSize = 20, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _emptyMembers = new() { FontSize = 13, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _emptyHint = new() { FontSize = 12, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Text = GroupRoomChrome.EmptyHint };
    private ChatFindBar? _find;
    private readonly StackPanel _transcript = new() { Padding = new Thickness(0, 8, 0, 8) };
    private readonly ScrollViewer _scroller = new() { HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly StackPanel _typing = new() { Spacing = 8 };
    private readonly TextBlock _notice = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(24, 0, 24, 6), Visibility = Visibility.Collapsed };
    private readonly TextBox _composer = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 200, BorderThickness = new Thickness(0) };
    private readonly Button _send = new() { VerticalAlignment = VerticalAlignment.Bottom, Width = 32, Height = 32, Padding = new Thickness(0) };
    private readonly FontIcon _sendGlyph = new() { Glyph = "\uE74A", FontSize = 13 };
    /// The typing dots' waves on screen, one per dot of each typing row.
    private readonly List<Storyboard> _waves = [];
    /// Held so its AnimationsEnabledChanged keeps arriving: the dots start or stop when the setting changes.
    private readonly Windows.UI.ViewManagement.UISettings _ui = new();

    public GroupRoomPage()
    {
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        AutomationProperties.SetAutomationId(_title, TitleId);
        AutomationProperties.SetAutomationId(_avatar, AvatarId);
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Children = { _avatar, _title } };
        _status.Foreground = Brush("TextFillColorSecondaryBrush");
        var header = new StackPanel { Spacing = 2, Children = { titleRow, _status } };
        // The room's ⋯ (the chat's More button): its items are made as it opens, from the room's state then.
        AutomationProperties.SetAutomationId(_more, MoreId);
        AutomationProperties.SetName(_more, "More");
        ToolTipService.SetToolTip(_more, "More");
        _more.Content = new FontIcon { Glyph = "\uE712", FontSize = 14 };
        _more.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _more.BorderThickness = new Thickness(0);
        _more.Flyout = _moreMenu;
        _moreMenu.Opening += (_, _) => FillMore();
        var top = new Grid { Padding = new Thickness(16, 10, 16, 8), Children = { header, _more } };
        root.Children.Add(top);

        _transcript.Children.Add(_typing);
        _scroller.Content = _transcript;
        AutomationProperties.SetAutomationId(_scroller, "chat.transcript");
        Grid.SetRow(_scroller, 1);
        root.Children.Add(_scroller);

        // The empty room (RoomEmptyView): framed by the transcript's room, centred a little high, fitted to it on every
        // size change (RoomEmptyFit): short of room it leaves out the avatar, then the hint, then the members.
        AutomationProperties.SetAutomationId(_empty, EmptyId);
        AutomationProperties.SetAutomationId(_emptyName, "room.empty.name");
        AutomationProperties.SetAutomationId(_emptyMembers, "room.empty.members");
        AutomationProperties.SetAutomationId(_emptyHint, "room.empty.hint");
        _emptyMembers.Foreground = Brush("TextFillColorSecondaryBrush");
        _emptyHint.Foreground = Brush("TextFillColorSecondaryBrush");
        foreach (var e in new FrameworkElement[] { _emptyAvatar, _emptyName, _emptyMembers, _emptyHint }) _empty.Children.Add(e);
        _emptyRoom.Children.Add(_empty);
        _emptyRoom.SizeChanged += (_, e) => LayoutEmpty(e.NewSize.Width, e.NewSize.Height);
        Grid.SetRow(_emptyRoom, 1);
        root.Children.Add(_emptyRoom);

        AutomationProperties.SetAutomationId(_typing, TypingId);
        AutomationProperties.SetAutomationId(_notice, NoticeId);
        _notice.Foreground = Brush("TextFillColorSecondaryBrush");
        var under = new StackPanel { Children = { MakeMentions(), _notice } };
        Grid.SetRow(under, 2);
        root.Children.Add(under);

        AutomationProperties.SetAutomationId(_composer, "chat.composer");
        AutomationProperties.SetAutomationId(_send, "chat.send");
        _send.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        _send.Content = _sendGlyph;
        _composer.PreviewKeyDown += Composer_PreviewKeyDown;
        _composer.TextChanged += (_, _) =>
        {
            UpdateComposer();
            UpdateMentions();
        };
        _composer.SelectionChanged += (_, _) => UpdateMentions();
        _send.Click += (_, _) => SendOrStop();
        var box = new Grid { ColumnSpacing = 6 };
        box.ColumnDefinitions.Add(new ColumnDefinition());
        box.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        box.Children.Add(_composer);
        Grid.SetColumn(_send, 1);
        box.Children.Add(_send);
        var frame = new Border
        {
            CornerRadius = new CornerRadius(Features.Settings.ThemeService.State.DesktopLook ? 8 : 20), Padding = new Thickness(8, 4, 6, 4), Margin = new Thickness(16, 0, 16, 12), MaxWidth = 900,
            BorderThickness = new Thickness(1), BorderBrush = Brush("CardStrokeColorDefaultBrush"), Background = Brush("CardBackgroundFillColorDefaultBrush"),
            Child = box,
        };
        void PaintLook()
        {
            frame.CornerRadius = new CornerRadius(Features.Settings.ThemeService.State.DesktopLook ? 8 : 20);
            Background = Features.Settings.BackdropPainter.CreateBrush(Hermes.Core.Settings.BackdropPlace.Chats)
                ?? Brush("HQPageBrush");
        }
        Loaded += (_, _) =>
        {
            PaintLook();
            Features.Settings.ThemeService.Changed -= PaintLook;
            Features.Settings.ThemeService.Changed += PaintLook;
            Hermes.Core.Settings.BackdropPrefs.Changed -= PaintLook;
            Hermes.Core.Settings.BackdropPrefs.Changed += PaintLook;
            _ui.AnimationsEnabledChanged -= OnAnimationsChanged;
            _ui.AnimationsEnabledChanged += OnAnimationsChanged;
            _ui.TextScaleFactorChanged -= OnTextScaleChanged;
            _ui.TextScaleFactorChanged += OnTextScaleChanged;
        };
        Unloaded += (_, _) =>
        {
            Features.Settings.ThemeService.Changed -= PaintLook;
            Hermes.Core.Settings.BackdropPrefs.Changed -= PaintLook;
            _ui.AnimationsEnabledChanged -= OnAnimationsChanged;
            _ui.TextScaleFactorChanged -= OnTextScaleChanged;
        };
        Grid.SetRow(frame, 3);
        root.Children.Add(frame);
        Content = root;

        // Find in Chat over the room's transcript: the chat's own bar and keys (Ctrl+F, Ctrl+G / F3, Esc).
        _find = new ChatFindBar(new RoomFindHost(this));
        ChatFindFeature.InstallKeys(this, _find);
    }

    private void OnAnimationsChanged(Windows.UI.ViewManagement.UISettings sender, Windows.UI.ViewManagement.UISettingsAnimationsEnabledChangedEventArgs args)
    {
        if (AppShutdown.Stopping) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (AppShutdown.Stopping || !IsLoaded || _session is not { } session) return;
            ShownTyping = [];   // draw the rows again, with or without their waves
            ShowTyping(session.Typing);
        });
    }

    // The text size changed (Settings › Accessibility › Text size): the words are taller or shorter in the same room.
    private void OnTextScaleChanged(Windows.UI.ViewManagement.UISettings sender, object args)
    {
        if (AppShutdown.Stopping) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (AppShutdown.Stopping || !IsLoaded) return;
            LayoutEmpty(_emptyRoom.ActualWidth, _emptyRoom.ActualHeight);
        });
    }

    /// The room's transcript as Find's host: its messages, its rows, its scroller (every row is realised).
    private sealed class RoomFindHost(GroupRoomPage page) : IChatFindHost
    {
        public Control Transcript => page._scroller;
        public IReadOnlyList<ChatMessage> Messages => page._session?.Messages ?? [];
        public bool HasOlder => false;   // a room's transcript is all on this PC
        public Task LoadOlderAsync() => Task.CompletedTask;
        /// A room has no type-to-chat yet, so its box keeps taking the keyboard when Find closes (WIN-52's choice).
        public void KeyboardAfterClose(Control rest) => page._composer.Focus(FocusState.Programmatic);
        public bool Owns(MessageView view) => page._rows.Values.Any(r => r.View == view);
        public void BringIntoView(string messageId) { }
        public ScrollViewer? Scroller => page._scroller;
        public event Action? Changed { add => page.FindChanged += value; remove => page.FindChanged -= value; }
        public event Action? Closed { add => page.FindClosed += value; remove => page.FindClosed -= value; }
    }

    private event Action? FindChanged;
    private event Action? FindClosed;

    private static Brush Brush(string key) => ThemeBrushes.Get(key);

    // ------------------------------------------------------------------ what the walk reads

    public string? RoomKey => _session?.RoomKey;
    public string ShownTitle => _session?.Title ?? "";
    /// The profiles of the faces the title's group avatar wears.
    public IReadOnlyList<string> ShownFaces { get; private set; } = [];
    public bool StopShown => _sendGlyph.Glyph == GroupRoomChrome.SendButton(true).Glyph;
    public bool RoomRunning => _session?.RoomRunning == true;
    public string ComposerText => _composer.Text;
    /// The typing rows as drawn: each one's words and the profile of the face it wears.
    public IReadOnlyList<(string Label, string? Face)> ShownTyping { get; private set; } = [];
    public bool EmptyShown => _emptyRoom.Visibility == Visibility.Visible;
    /// [WIN-GROUP-EMPTY-FIT] The empty room as last fitted to the transcript's room (null until it is laid out).
    public RoomEmptyFit.Layout? EmptyFit { get; private set; }
    public ChatFindBar? FindBar => _find;
    /// The ⋯ menu's items as it would open now, by automation id.
    public IReadOnlyList<string> MoreIds() { FillMore(); return [.. _moreMenu.Items.Select(i => AutomationProperties.GetAutomationId(i)).Where(i => i.Length > 0)]; }
    /// The ⋯ menu's Find in Chat, as its click does.
    public void AutomationFindInChat() => _find?.Open();
    /// The ⋯ menu's Activity, as its click does.
    public void AutomationActivity() { if (_session is { } s && ListsHub.Current is { } hub) _ = ShowActivity(hub, s.RoomKey); }
    /// Whether the system lets things animate now (UISettings.AnimationsEnabled), and the typing dots' waves: each
    /// one's running and how far into its clock it is.
    public (bool Animations, IReadOnlyList<bool> Running, IReadOnlyList<double> Times) DotsNow() =>
        (_ui.AnimationsEnabled,
         [.. _waves.Select(w => w.GetCurrentState() == ClockState.Active)],
         [.. _waves.Select(w => w.GetCurrentTime().TotalSeconds)]);
    /// The dots of the typing rows (not a wave's own count): what the walk checks when animations are off.
    public int DotsShown => _typing.Children.Count * TypingDots.Count;
    public string EmptyName => _emptyName.Text;
    public string EmptyMembers => _emptyMembers.Text;
    public string EmptyHint => _emptyHint.Text;
    public void CloseMore() => _moreMenu.Hide();

    /// The rows top to bottom as drawn: the sender line each shows, the role, the words.
    public IReadOnlyList<(string? Sender, string Role, string Text)> ShownRows() =>
        [.. _transcript.Children.OfType<MessageView>().Where(v => v.Item != null).Select(v =>
            (SenderShown(v), v.Item!.Role == Role.User ? "user" : v.Item.Role == Role.Assistant ? "assistant" : "system", v.Item.Text))];

    private static string? SenderShown(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is TextBlock t && AutomationProperties.GetAutomationId(t) == MessageView.SenderNameId) return t.Text;
            if (SenderShown(child) is { } deeper) return deeper;
        }
        return null;
    }

    /// The walk's send: the words into the box and Send, as Enter does.
    public void AutomationSend(string text) { _composer.Text = text; SendOrStop(); }

    // ------------------------------------------------------------------ lifecycle

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is not Args args || GroupRooms.Open(args.Key) is not { } session)
        {
            _title.Text = "";
            _status.Text = "This group chat isn't on this PC anymore.";
            return;
        }
        Current = this;
        _session = session;
        _roomGone = false;
        _composer.IsEnabled = true;
        session.ConnectionProvider = () => AppState.Client?.Rpc.State ?? Hermes.Core.Rpc.ConnectionState.Offline;
        session.OnChange = _ => Dirty();
        session.OnChromeChange = Dirty;
        session.OnRoomGone = name => DispatcherQueue.TryEnqueue(() =>
        {
            _roomGone = true;
            _status.Text = $"“{name}” was deleted.";
            _composer.IsEnabled = false;
            UpdateComposer();
        });
        _composer.PlaceholderText = GroupRoomChrome.Placeholder(session.Title);
        GroupRoomChrome.Open(session);   // read: the sidebar row loses the bold and the dot
        Apply();
        ScrollToEnd();
        if (!_composer.Focus(FocusState.Programmatic))
        {
            void Again(object sender, RoutedEventArgs _)
            {
                Loaded -= Again;
                _composer.Focus(FocusState.Programmatic);
            }
            Loaded += Again;
        }
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        if (Current == this) Current = null;
        StopWaves();
        ShownTyping = [];   // a page shown again draws its rows, and their waves, afresh
        _typing.Children.Clear();
        _find?.Close();
        FindClosed?.Invoke();
        if (_session is { } session)
        {
            session.StopObserving();
            session.OnChange = null;
            session.OnChromeChange = null;
            session.OnRoomGone = null;
            session.Dispose();
        }
        _session = null;
    }

    private void Dirty()
    {
        if (AppShutdown.Stopping || Interlocked.Exchange(ref _dirty, 1) == 1) return;
        DispatcherQueue.TryEnqueue(() => { if (!AppShutdown.Stopping) Apply(); });
    }

    private void Apply()
    {
        Interlocked.Exchange(ref _dirty, 0);
        if (_session is not { } session) return;
        var atEnd = _scroller.VerticalOffset >= _scroller.ScrollableHeight - 60;
        _title.Text = session.Title.ToUpperInvariant();
        _composer.PlaceholderText = GroupRoomChrome.Placeholder(session.Title);
        if (!_roomGone) _status.Text = session.RoomStatusLine;
        ShowAvatar(session);
        var messages = session.Messages;
        var views = new List<MessageView>(messages.Count);
        var seen = new HashSet<string>();
        // Day lines as a bot chat's (ChatViewModel.Displays: ChatRowBuilder.needsDayBreak / dayLabel, Fewer Timestamps).
        var fewer = ChatDisplaySettings.FewerTimestamps;
        var now = DateTimeOffset.Now;
        DateTimeOffset? lastTimed = null;
        for (var i = 0; i < messages.Count; i++)
        {
            var m = messages[i];
            seen.Add(m.Id);
            string? day = null;
            if (m.Timestamp is { } t && (m.Parts.Count > 0 || m.Error != null))
            {
                if (DayLines.NeedsBreak(lastTimed, t, fewer)) day = DayLines.Label(t, now);
                lastTimed = t;
            }
            var display = new MessageDisplay(day, MessageRuns.At(messages, i, fewer, day != null), new ReplyContext { BotName = m.Sender?.Name ?? session.Title }, null)
            {
                ShowsSender = GroupRoomChrome.ShowsSenderName(messages, i, dayLineAbove: day != null),
            };
            if (_rows.TryGetValue(m.Id, out var row)) row.Item.Update(m, display);
            else
            {
                var item = new MessageItem(m, null, display);
                row = (item, new MessageView { Item = item });
                _rows[m.Id] = row;
            }
            views.Add(row.View);
        }
        foreach (var gone in _rows.Keys.Where(k => !seen.Contains(k)).ToList()) _rows.Remove(gone);
        var existing = _transcript.Children.OfType<MessageView>().ToList();
        if (!existing.SequenceEqual(views))
        {
            // Append incrementally when only new messages were added at the end, preserving scroll & text selection.
            if (views.Count > existing.Count && views.Take(existing.Count).SequenceEqual(existing))
            {
                var insertAt = _transcript.Children.IndexOf(_typing);
                if (insertAt < 0) insertAt = _transcript.Children.Count;
                for (var i = existing.Count; i < views.Count; i++)
                    _transcript.Children.Insert(insertAt++, views[i]);
            }
            else
            {
                _transcript.Children.Clear();
                foreach (var v in views) _transcript.Children.Add(v);
                _transcript.Children.Add(_typing);   // the typing rows stay at the newest end
            }
        }
        ShowTyping(session.Typing);
        ShowEmpty(session, messages);
        FindChanged?.Invoke();
        UpdateComposer();
        if (atEnd) ScrollToEnd();
    }

    /// A room's typing rows (ChatRow.swift: one `.waiting(plain: true)` row per member answering, at the newest end;
    /// ChatCells.swift WaitingCell): the member's 28 pt face at the bubbles' edge, the three dots in the bot bubble's
    /// capsule, and the words in the secondary label colour. Plain: no timer (GroupRoomChrome.TypingTimer).
    private void ShowTyping(IReadOnlyList<RoomTyping> typing)
    {
        var shown = typing.Select(t => (t.Label, t.Sender?.Profile)).ToList();
        if (shown.SequenceEqual(ShownTyping) && _typing.Children.Count == shown.Count) return;
        ShownTyping = shown;
        StopWaves();
        _typing.Children.Clear();
        var moving = TypingDots.Animates(_ui.AnimationsEnabled);
        var clock = Environment.TickCount64 / 1000.0;   // the shared clock: a row drawn again doesn't restart the wave
        _typing.Margin = new Thickness(0, typing.Count > 0 ? 8 : 0, 0, 0);
        foreach (var who in typing)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(24, 0, 24, 0) };   // the transcript's side inset (MessageView)
            AutomationProperties.SetAutomationId(row, TypingId);
            AutomationProperties.SetName(row, who.Label);
            var face = new BotHead { Width = 28, Height = 28, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
            if (who.Sender is { } sender)
            {
                if (ListsHub.Current?.Bots.Bot(sender.Profile)?.Model is { } bot) face.Bot = bot;
                else face.DisplayName = sender.Profile;
                AutomationProperties.SetAutomationId(face, "chat.typing.face");
            }
            else face.Visibility = Visibility.Collapsed;
            row.Children.Add(face);
            var dots = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
            var pending = new List<(UIElement Dot, int Index)>();
            for (var d = 0; d < TypingDots.Count; d++)
            {
                var dot = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = TypingDots.Side, Height = TypingDots.Side, Fill = Brush("TextFillColorSecondaryBrush"), Opacity = TypingDots.StillOpacity };
                AutomationProperties.SetAutomationId(dot, $"chat.typing.dot.{d}");
                dots.Children.Add(dot);
                if (moving) pending.Add((dot, d));
            }
            row.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(14), Height = 28, Padding = new Thickness(12, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center,
                Background = Brush("CardBackgroundFillColorSecondaryBrush"), Child = dots,
            });
            row.Children.Add(new TextBlock
            {
                Text = who.Label, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Foreground = Brush("TextFillColorSecondaryBrush"),
            });
            _typing.Children.Add(row);
            foreach (var (dot, index) in pending)   // in the live tree first, then its wave
            {
                try { _waves.Add(Wave(dot, index, clock)); }
                catch (System.Runtime.InteropServices.COMException) { AppLog.Note("groups", "a typing dot's wave didn't start; the dot stays still"); }
            }
        }
    }

    /// One dot's wave (ChatCells.swift `animate`): opacity 0.3 → 1 → 0.3 → 0.3 at 0, ¼, ½, 1 of 1.2 s, ease-in-ease-out
    /// into and out of the peak (a KeySpline on Core Animation's control points), linear at rest, forever, started where
    /// the shared clock says the dot is.
    internal static Storyboard Wave(UIElement dot, int index, double clock)
    {
        var frames = new DoubleAnimationUsingKeyFrames();
        for (var k = 0; k < TypingDots.Keys.Count; k++)
        {
            var (at, opacity) = TypingDots.Keys[k];
            var time = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(at * TypingDots.Period));
            DoubleKeyFrame frame = k == 0 ? new DiscreteDoubleKeyFrame()
                : TypingDots.Curves[k - 1] == TypingDots.Curve.Linear ? new LinearDoubleKeyFrame()
                : new SplineDoubleKeyFrame
                {
                    KeySpline = new KeySpline
                    {
                        ControlPoint1 = new Windows.Foundation.Point(TypingDots.EaseInEaseOut.X1, TypingDots.EaseInEaseOut.Y1),
                        ControlPoint2 = new Windows.Foundation.Point(TypingDots.EaseInEaseOut.X2, TypingDots.EaseInEaseOut.Y2),
                    },
                };
            frame.KeyTime = time;
            frame.Value = opacity;
            frames.KeyFrames.Add(frame);
        }
        Storyboard.SetTarget(frames, dot);
        Storyboard.SetTargetProperty(frames, "Opacity");
        var wave = new Storyboard { RepeatBehavior = RepeatBehavior.Forever, Duration = new Duration(TimeSpan.FromSeconds(TypingDots.Period)) };
        wave.Children.Add(frames);
        wave.Begin();
        wave.Seek(TimeSpan.FromSeconds(TypingDots.Offset(index, clock)));
        return wave;
    }

    private void StopWaves()
    {
        foreach (var wave in _waves) wave.Stop();
        _waves.Clear();
    }

    /// The empty room (RoomEmptyView): the group avatar at 56, the name, the members (or "No bots yet"), the hint.
    private void ShowEmpty(GroupRoomSession session, IReadOnlyList<ChatMessage> messages)
    {
        var empty = GroupRoomChrome.IsEmpty(messages, session.Typing);
        _emptyRoom.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        if (!empty)
        {
            _emptyRoom.Clip = null;   // nothing over the rows or the typing row
            return;
        }
        var words = RoomEmptyFit.Words(session.Title, session.MemberNames);
        _emptyName.Text = words.Name;
        _emptyMembers.Text = words.Members;
        _emptyHint.Text = words.Hint;
        // refreshEmpty: the avatar is configured on every refresh, so a room whose members, photo or key changed (or a
        // page shown again for another room) never keeps the last one's faces.
        var hub = ListsHub.Current;
        if (hub?.Groups.Room(session.RoomKey) is { } room && hub.Groups.Rows().FirstOrDefault(r => r.Id == session.RoomKey) is { } row)
        {
            var faces = GroupRoomChrome.Faces(hub.Groups, room);
            var key = session.RoomKey + "\n" + row.Image + "\n" + string.Join(",", faces.Select(f => f.Profile));
            if (key != _emptyAvatarKey)
            {
                _emptyAvatarKey = key;
                _emptyAvatar.Children.Clear();
                _emptyAvatar.Children.Add(new GroupAvatar(row with { Faces = faces }, RoomEmptyFit.AvatarSide, p => hub.Bots.Bot(p)?.Model));
            }
        }
        LayoutEmpty(_emptyRoom.ActualWidth, _emptyRoom.ActualHeight);
    }

    /// [WIN-GROUP-EMPTY-FIT] RoomEmptyView `layoutSubviews` in the transcript's room (effective pixels, as laid out):
    /// every part shown again, the words measured at the column's width (WinUI applies the text size to them, so it is
    /// counted once), then RoomEmptyFit leaves out what doesn't fit and places the column. Runs on every size change
    /// of the room and of the text size, so a window made taller gets the avatar, hint and members back in place.
    private void LayoutEmpty(double width, double height)
    {
        if (_emptyRoom.Visibility != Visibility.Visible || (width <= 0 && height <= 0)) return;
        var column = RoomEmptyFit.Column(width);
        _empty.Width = column;
        double Measured(TextBlock text)
        {
            text.Visibility = Visibility.Visible;
            text.Margin = new Thickness(0);
            text.Measure(new Windows.Foundation.Size(column, double.PositiveInfinity));
            return text.DesiredSize.Height;
        }
        var fit = RoomEmptyFit.Fit(width, height, Measured(_emptyName), Measured(_emptyMembers), Measured(_emptyHint));
        var parts = new (RoomEmptyFit.Part Part, FrameworkElement View)[]
        {
            (RoomEmptyFit.Part.Avatar, _emptyAvatar), (RoomEmptyFit.Part.Name, _emptyName),
            (RoomEmptyFit.Part.Members, _emptyMembers), (RoomEmptyFit.Part.Hint, _emptyHint),
        };
        foreach (var (part, view) in parts)
        {
            view.Visibility = fit.Shows(part) ? Visibility.Visible : Visibility.Collapsed;
            view.Margin = new Thickness(0, fit.GapAbove(part), 0, 0);
        }
        _empty.Margin = new Thickness(0, fit.Top, 0, 0);
        _emptyRoom.Clip = fit.Clips ? new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, width, height) } : null;
        EmptyFit = fit;
    }

    // ------------------------------------------------------------------ ⋯

    /// The room's ⋯ (GroupRoomChrome.swift `moreItems`), made as it opens.
    private void FillMore()
    {
        _moreMenu.Items.Clear();
        if (_session is not { } session || ListsHub.Current is not { } hub) return;
        var key = session.RoomKey;
        var online = GroupManageFeature.Writable(hub);
        var fixedMembers = hub.Groups.Room(key)?.IsHosted == true;
        var sections = GroupRoomChrome.MoreItems(online, fixedMembers, session.RoomRunning, session.Paused.Count > 0);
        for (var n = 0; n < sections.Count; n++)
        {
            if (n > 0) _moreMenu.Items.Add(new MenuFlyoutSeparator());
            foreach (var node in sections[n])
            {
                var (glyph, run) = node.Id switch
                {
                    "find" => ("\uE721", (Action)(() => _find?.Open())),
                    "info" => ("\uE946", () => { if (XamlRoot != null) _ = GroupManageFeature.ShowInfoAsync(XamlRoot, key); }),
                    "add" => ("\uE8FA", () => _ = GroupManageFeature.ShowPickerAsync(hub, XamlRoot, key)),
                    "prompts" => ("\uE8F1", () => _ = ShowPrompts()),
                    "activity" => ("\uE81C", () => _ = ShowActivity(hub, key)),
                    "stop" => ("\uE71A", Stop),
                    "resume" => ("\uE768", () => session.ResumeAll()),
                    "delete" => ("\uE74D", () => { if (XamlRoot != null) _ = GroupManageFeature.ConfirmDeleteAsync(XamlRoot, key); }),
                    _ => ("", () => { }),
                };
                var item = new MenuFlyoutItem { Text = node.Title, Icon = new FontIcon { Glyph = glyph } };
                AutomationProperties.SetAutomationId(item, node.AutomationId);
                if (node.Destructive) item.Foreground = Brush("SystemFillColorCriticalBrush");
                item.Click += (_, _) => run();
                _moreMenu.Items.Add(item);
            }
        }
    }

    /// ⋯ › Prompts: the saved prompts go into this room's field as in a bot's chat (`menus.presentPrompts`); nothing sends.
    private Task ShowPrompts() => XamlRoot == null ? Task.CompletedTask : PromptsDialog.ShowAsync(XamlRoot, ComposerServices.Prompts, _composer);

    /// ⋯ › Activity: the Mac's sheet (GroupInfoSheet.swift GroupActivityView), newest first, Esc closes it.
    private Task ShowActivity(ListsHub hub, string key) => XamlRoot == null ? Task.CompletedTask : GroupActivityDialog.ShowAsync(XamlRoot, hub, key);

    private void ShowAvatar(GroupRoomSession session)
    {
        var hub = ListsHub.Current;
        if (hub?.Groups.Room(session.RoomKey) is not { } room) return;
        var faces = GroupRoomChrome.Faces(hub.Groups, room).Select(f => f.Profile).ToList();
        if (faces.SequenceEqual(ShownFaces) && _shownAvatarImage == room.Image && _avatar.Children.Count > 0) return;
        ShownFaces = faces;
        _shownAvatarImage = room.Image;
        var row = hub.Groups.Rows().FirstOrDefault(r => r.Id == session.RoomKey);
        if (row == null) return;
        _avatar.Children.Clear();
        _avatar.Children.Add(new GroupAvatar(row with { Faces = GroupRoomChrome.Faces(hub.Groups, room) }, GroupRoomChrome.TitleAvatarSide, p => hub.Bots.Bot(p)?.Model));
    }

    private async void ScrollToEnd()
    {
        try
        {
            var session = _session;
            for (var pass = 0; pass < 3; pass++)
            {
                if (AppShutdown.Stopping || _session != session || session == null) return;
                _scroller.UpdateLayout();
                _scroller.ChangeView(null, _scroller.ScrollableHeight, null, disableAnimation: true);
                await Task.Delay(40);
            }
        }
        catch (Exception ex) { AppLog.Error("groups", ex); }
    }

    // ------------------------------------------------------------------ the composer

    private bool OffersStop => !_roomGone && _session?.RoomRunning == true && _composer.Text.Trim().Length == 0;

    private void UpdateComposer()
    {
        var (glyph, tip) = GroupRoomChrome.SendButton(OffersStop);
        _sendGlyph.Glyph = glyph;
        ToolTipService.SetToolTip(_send, tip);
        _send.IsEnabled = !_roomGone && (OffersStop || _composer.Text.Trim().Length > 0);
    }

    private void Composer_PreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down);
        if (HandleKey(e.Key, shift)) e.Handled = true;
    }

    /// The message box's keys: true when the page took the key. The @ list's keys come first, as the field's drawer keys
    /// do on the Mac (GroupRoomChrome.swift `install`).
    private bool HandleKey(VirtualKey key, bool shift)
    {
        if (MentionKey(key, shift)) return true;
        if (key == VirtualKey.Enter)
        {
            if (shift) return false;   // a new line
            if (_composer.Text.Trim().Length > 0) SendOrStop();
            return true;
        }
        if (key == VirtualKey.Escape && _find?.IsOpen == true)
        {
            _find.Close();   // Esc's ladder: an open Find closes before the round is stopped (KeyRules.swift)
            return true;
        }
        if (key == VirtualKey.Escape && _session?.RoomRunning == true)
        {
            Stop();
            return true;
        }
        return false;
    }

    private void SendOrStop()
    {
        if (_session is not { } session) return;
        if (OffersStop) { Stop(); return; }
        var text = _composer.Text;
        if (text.Trim().Length == 0) return;
        _notice.Visibility = Visibility.Collapsed;
        switch (session.Refusal(text))
        {
            case RoomSendRefusal.SlashCommand:
                _notice.Text = GroupRoomSession.SlashNotice;
                _notice.Visibility = Visibility.Visible;
                return;
            case RoomSendRefusal.NoMembers(var name):
                _ = CantSend(name);
                return;
        }
        _composer.Text = "";
        session.Send(text);
        Apply();
        ScrollToEnd();
    }

    /// The composer's Stop square, Esc (`GroupRoomChrome.stop`): the round stops here at once; the gateway is asked to
    /// stop the reply in flight, and when it can't confirm, the alert says so.
    private async void Stop()
    {
        if (_stopping || _session is not { } session) return;
        _stopping = true;
        try
        {
            var confirmed = await session.StopRoomAsync();
            if (!confirmed && Current == this)
                await Alert("Couldn’t Confirm Stop", $"The group chat is paused, but {HostWord.Phrase} couldn’t confirm that the current reply stopped.", "OK");
        }
        catch (Exception ex) { AppLog.Error("groups", ex); }
        finally
        {
            _stopping = false;
            Apply();
        }
    }

    /// Can’t Send (GroupRoomChrome.swift `explain(.noMembers)`): Add Bots… while online with members that can change opens
    /// the room's picker, as ⋯ › Add Bots… does; OK closes.
    private async Task CantSend(string name)
    {
        if (XamlRoot == null || _session is not { } session) return;
        var key = session.RoomKey;
        var hub = ListsHub.Current;
        var buttons = GroupRoomChrome.CantSendButtons(hub != null && GroupManageFeature.Writable(hub), hub?.Groups.Room(key)?.IsHosted == true);
        var dialog = new ContentDialog
        {
            Title = GroupRoomChrome.CantSendTitle, Content = GroupRoomChrome.CantSendMessage(name), CloseButtonText = buttons[^1],
            XamlRoot = XamlRoot, DefaultButton = ContentDialogButton.Close,
        };
        if (buttons.Count > 1) dialog.PrimaryButtonText = buttons[0];
        try
        {
            if (await dialog.ShowAsync() == ContentDialogResult.Primary && hub != null && Current == this)
                await GroupManageFeature.ShowPickerAsync(hub, XamlRoot, key);
        }
        catch (Exception x) when (x is InvalidOperationException or System.Runtime.InteropServices.COMException) { AppLog.Note("groups", "alert not shown"); }
    }

    private async Task Alert(string title, string message, string close)
    {
        if (XamlRoot == null) return;
        var dialog = new ContentDialog { Title = title, Content = message, CloseButtonText = close, XamlRoot = XamlRoot, DefaultButton = ContentDialogButton.Close };
        try { await dialog.ShowAsync(); }
        catch (Exception x) when (x is InvalidOperationException or System.Runtime.InteropServices.COMException) { AppLog.Note("groups", "alert not shown"); }
    }
}
