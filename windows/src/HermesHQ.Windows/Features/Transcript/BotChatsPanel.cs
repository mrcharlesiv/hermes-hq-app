using Hermes.Core.Bots;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Sessions;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace HermesHQ.Features.Transcript;

/// The inspector's Chats tab beside any chat with a bot (App/Mac/BotChatsPanel.swift):
/// Bot Chat row at the top, "New Chat" action, then every non-archived, non-cron, non-tool chat of that bot grouped
/// into Active (working, then unread), Pinned, Today, and Earlier. Quiet single-line rows (title + time); a second
/// detail line appears only when a chat is working or has an unread reply. Rounded fill on hover and for the active chat.
public sealed class BotChatsPanel : UserControl
{
    private readonly StackPanel _list = new() { Spacing = 0, Padding = new Thickness(0, 4, 0, 12) };
    private readonly ScrollViewer _scroll;
    private ChatSession _session;
    private bool _isBotChat;
    private ListsHub? _subscribedHub;
    private string? _lastFingerprint;

    public BotChatsPanel(ChatSession session, bool isBotChat = false)
    {
        _session = session;
        _isBotChat = isBotChat;

        _scroll = new ScrollViewer
        {
            Content = _list,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        AutomationProperties.SetAutomationId(this, "mac.inspector.chats.panel");
        AutomationProperties.SetAutomationId(_scroll, "mac.inspector.chats.list");
        Content = _scroll;

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        Refresh(force: true);
    }

    /// Follows another chat shown beside the inspector without rebuilding the panel host (`BotChatsPanel.follow`).
    public void Follow(ChatSession session, bool isBotChat)
    {
        var changed = !ReferenceEquals(_session, session) || _isBotChat != isBotChat;
        _session = session;
        _isBotChat = isBotChat;
        if (changed) Refresh(force: false);
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        AttachHub();
        ThemeService.Changed -= OnThemeChanged;
        ThemeService.Changed += OnThemeChanged;
        Refresh(force: true);
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        DetachHub();
        ThemeService.Changed -= OnThemeChanged;
    }

    private void AttachHub()
    {
        var current = ListsHub.Current;
        if (ReferenceEquals(_subscribedHub, current)) return;
        DetachHub();
        _subscribedHub = current;
        if (_subscribedHub != null) _subscribedHub.Changed += OnHubChanged;
    }

    private void DetachHub()
    {
        if (_subscribedHub != null)
        {
            _subscribedHub.Changed -= OnHubChanged;
            _subscribedHub = null;
        }
    }

    private void OnHubChanged() => DispatcherQueue?.TryEnqueue(() => Refresh(force: false));
    private void OnThemeChanged() => DispatcherQueue?.TryEnqueue(() => Refresh(force: true));

    public void Refresh(bool force = false)
    {
        if (AppShutdown.Stopping) return;
        AttachHub();

        var profile = SessionStripRules.NormalizeProfile(_session.Profile);
        var hub = ListsHub.Current;
        var bot = hub?.Bots.Bot(profile);
        var onBotChat = _isBotChat || _session.Title == Bot.BotChatTitle;
        var currentId = onBotChat ? null : _session.StoredId;
        var canonicalId = bot?.RegistryId ?? bot?.OpenId;
        var sessions = hub?.Sessions.LiveSummaries() ?? [];
        var groups = SessionStripRules.GroupsForBot(profile, sessions, DateTimeOffset.Now, canonicalId);

        var fingerprint = BuildFingerprint(profile, onBotChat, currentId, bot, groups);
        if (!force && fingerprint == _lastFingerprint && _list.Children.Count > 0) return;
        _lastFingerprint = fingerprint;

        _list.Children.Clear();

        if (bot == null && groups.Count == 0)
        {
            _list.Children.Add(EmptyNote());
            return;
        }

        if (bot != null)
        {
            var botUnread = bot.Unread && !onBotChat;
            var botRow = BuildRow(
                title: "Bot Chat",
                detail: "",
                time: "",
                tooltip: $"Your ongoing chat with {bot.Name}",
                working: bot.IsWorking,
                unread: botUnread,
                current: onBotChat,
                glyph: "\uE99A", // Robot
                automationId: "mac.inspector.chats.bot",
                onClick: () =>
                {
                    if (!onBotChat) Navigator.Go(new BotChatDestination(bot.Model));
                });
            _list.Children.Add(botRow);
        }

        var newChatRow = BuildRow(
            title: "New Chat",
            detail: "",
            time: "",
            tooltip: "New Chat",
            working: false,
            unread: false,
            current: false,
            glyph: "\uE710", // Add
            automationId: "mac.inspector.chats.new",
            onClick: () => _ = StartNewChatAsync(profile));
        _list.Children.Add(newChatRow);

        var chatIndex = 0;
        foreach (var group in groups)
        {
            _list.Children.Add(BuildHeader(group.Title));
            foreach (var chat in group.Chats)
            {
                var working = SessionStripRules.IsWorking(chat);
                var current = !onBotChat && chat.Id == currentId;
                var unread = chat.Unread && !current;
                var detail = SessionStripRules.PanelDetail(chat, current);
                var preview = SessionStripRules.CompactPreview(chat.Preview);
                var time = working ? "" : ListTime.Format(chat.LastActive);
                var tip = preview.Length == 0 ? chat.Title : $"{chat.Title}\n{preview}";
                var target = chat;

                var row = BuildRow(
                    title: chat.Title,
                    detail: detail,
                    time: time,
                    tooltip: tip,
                    working: working,
                    unread: unread,
                    current: current,
                    glyph: null,
                    automationId: $"mac.inspector.chats.chat.{chatIndex}",
                    onClick: () =>
                    {
                        if (!current) Navigator.Go(new ChatDestination(profile, target.Id, target.Title));
                    });
                _list.Children.Add(row);
                chatIndex++;
            }
        }
    }

    private async Task StartNewChatAsync(string profile)
    {
        var hub = ListsHub.Current;
        if (hub == null) return;
        string? id = null;
        await Prompts.RunAsync(XamlRoot, "Couldn’t Start a New Chat", async () => id = await hub.Sessions.NewChatAsync(profile));
        if (id != null) Navigator.Go(new ChatDestination(profile, id, "New Chat"));
    }

    private static FrameworkElement BuildHeader(string title)
    {
        var header = new TextBlock
        {
            Text = title,
            FontSize = 11.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
            Margin = new Thickness(16, 12, 12, 4),
        };
        AutomationProperties.SetAutomationId(header, $"mac.inspector.chats.group.{title.ToLowerInvariant()}");
        return header;
    }

    private static FrameworkElement BuildRow(
        string title,
        string detail,
        string time,
        string tooltip,
        bool working,
        bool unread,
        bool current,
        string? glyph,
        string automationId,
        Action onClick)
    {
        var dotted = working || unread;

        var leading = new Grid { Width = 16, VerticalAlignment = VerticalAlignment.Center };
        if (dotted)
        {
            leading.Children.Add(new Ellipse
            {
                Width = 7,
                Height = 7,
                Fill = ThemeBrushes.Get(working ? "HQGreenBrush" : "HQTintBrush"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        else if (!string.IsNullOrEmpty(glyph))
        {
            leading.Children.Add(new FontIcon
            {
                Glyph = glyph,
                FontSize = glyph == "\uE710" ? 12 : 14,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }

        var firstLine = new Grid { ColumnSpacing = 8 };
        firstLine.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        firstLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var titleText = new TextBlock
        {
            Text = title,
            FontSize = 13,
            FontWeight = current || unread ? FontWeights.SemiBold : FontWeights.Normal,
            Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
            VerticalAlignment = VerticalAlignment.Center,
        };
        firstLine.Children.Add(titleText);

        if (time.Length > 0)
        {
            var timeText = new TextBlock
            {
                Text = time,
                FontSize = 11.5,
                Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(timeText, 1);
            firstLine.Children.Add(timeText);
        }

        var lines = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        lines.Children.Add(firstLine);
        if (detail.Length > 0)
        {
            lines.Children.Add(new TextBlock
            {
                Text = detail,
                FontSize = 11.5,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1,
            });
        }

        var rowGrid = new Grid { ColumnSpacing = 8 };
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        rowGrid.Children.Add(leading);
        Grid.SetColumn(lines, 1);
        rowGrid.Children.Add(lines);

        var restFill = current ? ThemeBrushes.Get("HQPressedBrush") : new SolidColorBrush(Colors.Transparent);
        var pill = new Border
        {
            Child = rowGrid,
            CornerRadius = new CornerRadius(6),
            Background = restFill,
            Padding = new Thickness(8, 6, 8, 6),
        };

        var button = new Button
        {
            Content = pill,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            Margin = new Thickness(8, 1, 8, 1),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
        };

        if (!current)
        {
            button.PointerEntered += (_, _) => pill.Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush");
            button.PointerExited += (_, _) => pill.Background = restFill;
        }

        if (tooltip.Length > 0) ToolTipService.SetToolTip(button, tooltip);
        AutomationProperties.SetAutomationId(button, automationId);

        var spoken = new List<string> { title };
        if (working) spoken.Add("Working");
        if (unread) spoken.Add("New reply");
        if (detail.Length > 0) spoken.Add(detail);
        if (time.Length > 0) spoken.Add(time);
        AutomationProperties.SetName(button, string.Join(", ", spoken));

        button.Click += (_, _) => onClick();
        return button;
    }

    private static FrameworkElement EmptyNote()
    {
        var stack = new StackPanel
        {
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(24),
        };
        stack.Children.Add(new FontIcon { Glyph = "\uE8F2", FontSize = 28, Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush") });
        stack.Children.Add(new TextBlock { Text = "No Chats", FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
        stack.Children.Add(new TextBlock
        {
            Text = "A bot’s chats are listed here, beside any chat with it.",
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
        });
        return stack;
    }

    private static string BuildFingerprint(string profile, bool onBotChat, string? currentId, BotRow? bot, IReadOnlyList<BotChatGroup> groups)
    {
        var botPart = bot == null ? "-" : $"{bot.Id}|{bot.Name}|{bot.IsWorking}|{bot.Unread}";
        var groupPart = string.Join(";", groups.Select(g => g.Title + ":" + string.Join(",", g.Chats.Select(c =>
            $"{c.Id}|{c.Title}|{c.IsRunning}|{(int)c.Status}|{c.Unread}|{c.Pinned}|{c.Step}|{c.Preview}|{c.LastActive?.ToUnixTimeSeconds()}"))));
        return $"{ThemeService.Dark}|{profile}|{onBotChat}|{currentId}|{botPart}|{groupPart}";
    }
}
