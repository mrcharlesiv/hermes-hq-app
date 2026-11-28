using Hermes.Core.Bots;
using Hermes.Core.Sessions;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Settings;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace HermesHQ.Controls;

/// Secondary tab strip directly under a chat's header (App/Chat/SessionStrip.swift, `feat/mac-session-tabs`):
/// pinned Bot Chat tab on the left, vertical rule, horizontally scrolling live/current session tabs in settled order
/// (soft accent fill + bottom underline for the active tab, green working / blue unread dots), "All N ›" to open
/// Inspector › Chats (`BotChatsPanel`), and "+" to start a new chat. Right-click offers Open, Mark as Read,
/// Pin / Unpin, Remove from Tabs, and Archive. Hidden on task chats, group rooms, or when `SessionStripRules.IsEnabled` is off.
public sealed class SessionStrip : UserControl
{
    private static readonly Dictionary<string, HashSet<string>> ShownBefore = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, List<string>> TabOrder = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, HashSet<string>> Dismissed = new(StringComparer.Ordinal);

    /// Fired when a tab is removed via "Remove from Tabs" so visible strips refresh.
    public static event Action? StateChanged;

    private readonly Border _frame;
    private readonly Grid _pinnedSlot = new() { VerticalAlignment = VerticalAlignment.Stretch };
    private readonly Border _leftRule;
    private readonly ScrollViewer _scroller;
    private readonly StackPanel _row = new() { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _allButton;
    private readonly TextBlock _allText;
    private readonly Border _rightRule;
    private readonly Button _newChatButton;

    private string _profile = "default";
    private string? _currentSessionId;
    private bool _isBotChat;
    private bool _isTaskChat;
    private bool _isGroupRoom;
    private bool _configured;
    private string? _lastFingerprint;

    /// Invoked when the user clicks "All N ›" on the right to open Inspector › Chats.
    public event Action? OpenAllChatsRequested;

    /// Optional override for the trailing "+" New Chat button; when null, starts a new chat for the active bot.
    public event Action? NewChatRequested;

    public SessionStrip()
    {
        SessionStripRules.Store ??= FilePreferences.Shared;
        Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(this, "chat.strip");

        _leftRule = MakeVerticalRule();
        _rightRule = MakeVerticalRule();

        _scroller = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollMode = ScrollMode.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollMode = ScrollMode.Disabled,
            Content = _row,
            VerticalAlignment = VerticalAlignment.Stretch,
            Padding = new Thickness(2, 0, 4, 0),
        };

        _allText = new TextBlock
        {
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var allContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        allContent.Children.Add(_allText);
        allContent.Children.Add(new FontIcon
        {
            Glyph = "\uE76C", // ChevronRight
            FontSize = 9,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        _allButton = new Button
        {
            Content = allContent,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(7, 3, 6, 3),
            MinHeight = 26,
            CornerRadius = new CornerRadius(6),
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_allButton, "chat.strip.all");
        AutomationProperties.SetName(_allButton, "All chats");
        ToolTipService.SetToolTip(_allButton, "All Chats");
        _allButton.Click += (_, _) => OpenAllChatsRequested?.Invoke();

        _newChatButton = new Button
        {
            Content = new FontIcon
            {
                Glyph = "\uE710", // Add
                FontSize = 11,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            },
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(6, 4, 6, 4),
            MinWidth = 26,
            MinHeight = 26,
            CornerRadius = new CornerRadius(6),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAutomationId(_newChatButton, "chat.strip.new");
        AutomationProperties.SetName(_newChatButton, "New Chat");
        ToolTipService.SetToolTip(_newChatButton, "New Chat");
        _newChatButton.Click += (_, _) => HandleNewChat();

        var grid = new Grid { MinHeight = 32 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // 0: pinned Bot Chat
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // 1: left rule
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); // 2: scrolling tabs
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // 3: All N
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // 4: right rule
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // 5: + New Chat

        grid.Children.Add(_pinnedSlot);
        Grid.SetColumn(_leftRule, 1);
        grid.Children.Add(_leftRule);
        Grid.SetColumn(_scroller, 2);
        grid.Children.Add(_scroller);
        Grid.SetColumn(_allButton, 3);
        grid.Children.Add(_allButton);
        Grid.SetColumn(_rightRule, 4);
        grid.Children.Add(_rightRule);
        Grid.SetColumn(_newChatButton, 5);
        grid.Children.Add(_newChatButton);

        _frame = new Border
        {
            Child = grid,
            Padding = new Thickness(8, 0, 10, 0),
            BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(0, 0, 0, 1),
        };
        Content = _frame;

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        SessionStripRules.Changed -= OnExternalChanged;
        SessionStripRules.Changed += OnExternalChanged;
        StateChanged -= OnExternalChanged;
        StateChanged += OnExternalChanged;
        ThemeService.Changed -= OnThemeChanged;
        ThemeService.Changed += OnThemeChanged;
        Refresh(force: true);
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        SessionStripRules.Changed -= OnExternalChanged;
        StateChanged -= OnExternalChanged;
        ThemeService.Changed -= OnThemeChanged;
    }

    private void OnExternalChanged() => DispatcherQueue?.TryEnqueue(() => Refresh(force: true));
    private void OnThemeChanged() => DispatcherQueue?.TryEnqueue(() => Refresh(force: true));

    /// Configures the strip for the currently displayed chat and refreshes it immediately.
    public void Configure(string profile, string? currentSessionId, bool isBotChat, bool isTaskChat = false, bool isGroupRoom = false)
    {
        _profile = SessionStripRules.NormalizeProfile(profile);
        _currentSessionId = currentSessionId;
        _isBotChat = isBotChat;
        _isTaskChat = isTaskChat;
        _isGroupRoom = isGroupRoom;
        _configured = true;
        Refresh(force: true);
    }

    /// Removes a non-live session tab from this bot's strip for the remainder of the run ("Remove from Tabs").
    public static void Forget(string profile, string sessionId)
    {
        if (string.IsNullOrEmpty(sessionId)) return;
        var key = ScopeKey(profile);
        if (ShownBefore.TryGetValue(key, out var kept)) kept.Remove(sessionId);
        if (!Dismissed.TryGetValue(key, out var dismissed)) Dismissed[key] = dismissed = new HashSet<string>(StringComparer.Ordinal);
        dismissed.Add(sessionId);
        StateChanged?.Invoke();
    }

    public void Refresh(bool force = false)
    {
        if (!_configured || AppShutdown.Stopping)
        {
            Visibility = Visibility.Collapsed;
            return;
        }
        if (!SessionStripRules.ShouldShow(isBotOrSessionChat: true, isTaskChat: _isTaskChat, isGroupRoom: _isGroupRoom))
        {
            _lastFingerprint = null;
            Visibility = Visibility.Collapsed;
            return;
        }

        var hub = ListsHub.Current;
        var bot = hub?.Bots.Bot(_profile);
        var sessions = hub?.Sessions.LiveSummaries() ?? [];
        var canonicalId = bot?.RegistryId ?? bot?.OpenId;
        var key = ScopeKey(_profile);

        if (!_isBotChat && !string.IsNullOrEmpty(_currentSessionId) && Dismissed.TryGetValue(key, out var dismissedSet))
            dismissedSet.Remove(_currentSessionId);

        ShownBefore.TryGetValue(key, out var keptIds);
        TabOrder.TryGetValue(key, out var previousOrder);
        Dismissed.TryGetValue(key, out var dismissedIds);

        var otherCount = SessionStripRules.ChatsForBot(_profile, sessions, canonicalId).Count;
        var entries = SessionStripRules.TabsForBot(
            _profile,
            sessions,
            _currentSessionId,
            dismissedIds,
            botName: bot?.Name,
            botCanonicalSessionId: canonicalId,
            botWorking: bot?.IsWorking == true,
            botUnread: bot?.Unread == true,
            onBotChat: _isBotChat,
            keptIds: keptIds,
            previousOrder: previousOrder);

        var (botEntry, sessionEntries) = SessionStripRules.Split(entries);
        if (sessionEntries.Count > 0)
        {
            if (!ShownBefore.TryGetValue(key, out var shown)) ShownBefore[key] = shown = new HashSet<string>(StringComparer.Ordinal);
            foreach (var s in sessionEntries) shown.Add(s.Id);
            TabOrder[key] = [.. sessionEntries.Select(s => s.Id)];
        }
        else
        {
            TabOrder.Remove(key);
        }

        if (!SessionStripRules.DrawsStrip(botEntry, sessionEntries, otherCount, _isBotChat))
        {
            _lastFingerprint = null;
            Visibility = Visibility.Collapsed;
            return;
        }

        Visibility = Visibility.Visible;

        var fingerprint = BuildFingerprint(botEntry, sessionEntries, otherCount);
        if (!force && fingerprint == _lastFingerprint) return;
        _lastFingerprint = fingerprint;

        // Pinned Bot Chat slot on the left.
        _pinnedSlot.Children.Clear();
        if (botEntry != null)
        {
            _pinnedSlot.Children.Add(BuildTab(botEntry, -1));
            _pinnedSlot.Visibility = Visibility.Visible;
            _leftRule.Visibility = sessionEntries.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        else
        {
            _pinnedSlot.Visibility = Visibility.Collapsed;
            _leftRule.Visibility = Visibility.Collapsed;
        }

        // Horizontally scrolling session tabs separated by subtle middots.
        _row.Children.Clear();
        for (var i = 0; i < sessionEntries.Count; i++)
        {
            if (i > 0) _row.Children.Add(MakeMiddot());
            _row.Children.Add(BuildTab(sessionEntries[i], i));
        }

        // Trailing "All N ›" and divider before "+".
        var showAll = otherCount > 0;
        _allButton.Visibility = showAll ? Visibility.Visible : Visibility.Collapsed;
        _rightRule.Visibility = showAll ? Visibility.Visible : Visibility.Collapsed;
        if (showAll)
        {
            _allText.Text = $"All {otherCount}";
            AutomationProperties.SetName(_allButton, $"All chats, {otherCount}");
        }
    }

    private Button BuildTab(SessionStripEntry entry, int index)
    {
        var live = entry.Working || entry.Unread;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };

        if (entry.Working)
        {
            row.Children.Add(new Ellipse
            {
                Width = 6, Height = 6,
                Fill = ThemeBrushes.Get("HQGreenBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        else if (entry.Unread)
        {
            row.Children.Add(new Ellipse
            {
                Width = 6, Height = 6,
                Fill = ThemeBrushes.Get("HQTintBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        else if (entry.IsBotChat)
        {
            row.Children.Add(new FontIcon
            {
                Glyph = "\uE99A", // Robot
                FontSize = 12,
                Foreground = ThemeBrushes.Get(entry.Current ? "TextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            });
        }

        row.Children.Add(new TextBlock
        {
            Text = entry.Title,
            FontSize = 12,
            FontWeight = entry.Current ? FontWeights.SemiBold : live ? FontWeights.Medium : FontWeights.Normal,
            Foreground = ThemeBrushes.Get(entry.Current || live ? "TextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var pillCorner = new CornerRadius(ThemeService.State.DesktopLook ? 5 : 6);
        var restFill = entry.Current ? CurrentTabFill() : new SolidColorBrush(Colors.Transparent);
        var pill = new Border
        {
            Child = row,
            CornerRadius = pillCorner,
            Background = restFill,
            Margin = new Thickness(1, 3, 1, 3),
            Padding = new Thickness(8, 3, 8, 3),
            VerticalAlignment = VerticalAlignment.Stretch,
        };

        var chrome = new Grid { VerticalAlignment = VerticalAlignment.Stretch };
        chrome.Children.Add(pill);

        if (entry.Current)
        {
            chrome.Children.Add(new Border
            {
                Height = 2,
                VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(8, 0, 8, 0),
                CornerRadius = new CornerRadius(1, 1, 0, 0),
                Background = ThemeBrushes.Get("HQTintBrush"),
                IsHitTestVisible = false,
            });
        }

        var button = new Button
        {
            Content = chrome,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            MinHeight = 30,
            MaxWidth = entry.IsBotChat ? 180 : 220,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
        };

        if (!entry.Current)
        {
            button.PointerEntered += (_, _) => pill.Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush");
            button.PointerExited += (_, _) => pill.Background = restFill;
        }

        var tip = entry.Detail.Length > 0
            ? $"{entry.Title}\n{entry.Detail}"
            : entry.IsBotChat ? $"{entry.Title} — Bot Chat" : entry.Title;
        ToolTipService.SetToolTip(button, tip);

        AutomationProperties.SetAutomationId(button, entry.IsBotChat ? "chat.strip.bot" : $"chat.strip.pill.{index}");
        var spoken = new List<string> { entry.Title };
        if (entry.IsBotChat) spoken.Add("Bot Chat");
        if (entry.Working) spoken.Add("Working");
        if (entry.Unread) spoken.Add("New reply");
        AutomationProperties.SetName(button, string.Join(", ", spoken));

        button.Click += (_, _) => OpenEntry(entry);

        if (!entry.IsBotChat)
        {
            var menu = new MenuFlyout();
            menu.Opening += (_, _) => FillTabMenu(menu, entry);
            button.ContextFlyout = menu;
        }

        return button;
    }

    private void FillTabMenu(MenuFlyout menu, SessionStripEntry entry)
    {
        menu.Items.Clear();
        if (!entry.Current)
        {
            menu.Items.Add(MenuItem("Open", "\uE8BD", () => OpenEntry(entry)));
        }
        if (entry.Unread)
        {
            menu.Items.Add(MenuItem("Mark as Read", "\uE8C3", () => ActOnSession(entry, "Couldn’t Mark Chat as Read",
                (store, chat) => store.SetUnreadAsync(chat, false))));
        }
        menu.Items.Add(MenuItem(
            entry.Pinned ? "Unpin" : "Pin",
            entry.Pinned ? "\uE77A" : "\uE718",
            () => ActOnSession(entry, entry.Pinned ? "Couldn’t Unpin Chat" : "Couldn’t Pin Chat",
                (store, chat) => store.SetPinnedAsync(chat, !entry.Pinned))));

        menu.Items.Add(new MenuFlyoutSeparator());

        if (!entry.Current && !entry.Working && !entry.Unread && !entry.Pinned)
        {
            menu.Items.Add(MenuItem("Remove from Tabs", "\uE711", () => Forget(_profile, entry.Id)));
        }
        menu.Items.Add(MenuItem("Archive", "\uE7B8", () => ArchiveSession(entry)));
    }

    private void OpenEntry(SessionStripEntry entry)
    {
        if (entry.Current) return;
        if (entry.IsBotChat)
        {
            if (ListsHub.Current?.Bots.Bot(_profile) is { } bot)
                Navigator.Go(new BotChatDestination(bot.Model));
            return;
        }
        Navigator.Go(new ChatDestination(_profile, entry.Id, entry.Title));
    }

    private void ActOnSession(SessionStripEntry entry, string failureTitle, Func<SessionStore, SessionSummary, Task> action)
    {
        var hub = ListsHub.Current;
        if (hub == null) return;
        var chat = hub.Sessions.LiveSummaries().FirstOrDefault(s => s.Id == entry.Id && SessionStripRules.SameBot(s.Profile, _profile));
        if (chat == null) return;
        _ = Prompts.RunAsync(XamlRoot, failureTitle, () => action(hub.Sessions, chat));
    }

    private async void ArchiveSession(SessionStripEntry entry)
    {
        var hub = ListsHub.Current;
        if (hub == null) return;
        var chat = hub.Sessions.LiveSummaries().FirstOrDefault(s => s.Id == entry.Id && SessionStripRules.SameBot(s.Profile, _profile));
        if (chat == null) return;
        if (!await Prompts.RunAsync(XamlRoot, "Couldn’t Archive Chat", () => hub.Sessions.SetArchivedAsync(chat, true))) return;
        if (entry.Current && hub.Bots.Bot(_profile) is { } bot)
            Navigator.Go(new BotChatDestination(bot.Model));
    }

    private async void HandleNewChat()
    {
        if (NewChatRequested != null)
        {
            NewChatRequested.Invoke();
            return;
        }
        var hub = ListsHub.Current;
        if (hub == null) return;
        string? id = null;
        await Prompts.RunAsync(XamlRoot, "Couldn’t Start a New Chat", async () => id = await hub.Sessions.NewChatAsync(_profile));
        if (id != null) Navigator.Go(new ChatDestination(_profile, id, "New Chat"));
    }

    private static Brush CurrentTabFill()
    {
        if (ThemeService.SystemHighContrast) return ThemeBrushes.Get("SubtleFillColorSecondaryBrush");
        var tint = ThemeService.ToColor(ThemeService.Tokens.Tint);
        return new SolidColorBrush(Color.FromArgb(31, tint.R, tint.G, tint.B));
    }

    private static Border MakeVerticalRule() => new()
    {
        Width = 1,
        Height = 12,
        Margin = new Thickness(4, 0, 4, 0),
        Background = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
        VerticalAlignment = VerticalAlignment.Center,
        IsHitTestVisible = false,
        Visibility = Visibility.Collapsed,
    };

    private static TextBlock MakeMiddot() => new()
    {
        Text = "·",
        FontSize = 12,
        FontWeight = FontWeights.SemiBold,
        Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
        Margin = new Thickness(1, 0, 1, 0),
        VerticalAlignment = VerticalAlignment.Center,
        IsHitTestVisible = false,
    };

    private static MenuFlyoutItem MenuItem(string text, string glyph, Action onClick)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
        item.Click += (_, _) => onClick();
        return item;
    }

    private static string ScopeKey(string profile) =>
        $"{AppState.Client?.AccountId ?? ""}\u001F{SessionStripRules.NormalizeProfile(profile)}";

    private static string BuildFingerprint(SessionStripEntry? bot, IReadOnlyList<SessionStripEntry> sessions, int otherCount)
    {
        static string Part(SessionStripEntry? e) => e == null ? "-" : $"{e.Id}|{e.Title}|{e.Working}|{e.Unread}|{e.Current}|{e.Pinned}|{e.Detail}";
        return $"{ThemeService.Dark}|{ThemeService.State.DesktopLook}|{otherCount}|{Part(bot)}|{string.Join(";", sessions.Select(Part))}";
    }
}
