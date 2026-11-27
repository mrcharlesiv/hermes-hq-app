using Hermes.Core.Chat;
using HermesHQ.Controls;
using HermesHQ.Features.Bots;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using HermesCoreIntro = Hermes.Core.Chat.ChatIntro;

namespace HermesHQ.Features.ChatIntro;

/// [WIN-CHAT-INTRO] An empty chat's intro (App/Chat/ChatPlaceholderView.swift `.empty` and `.blank`, ChatViewController
/// `updatePlaceholder` / `emptyIntro` at 93f984bb1): the bot's 80 px face, its name (the roster's, never the chat's
/// title), its role and description when they say something new, else "No messages yet. Say hello."; Bot Info under
/// them while the roster knows the bot, and Name Chat while the chat is unnamed and not the bot's own. With Settings ›
/// Chat › Greeting on Empty Chats off the area is blank but a screen reader still hears "No messages yet".
/// Gone the moment the chat has a row (the first send's own row), and never over a loading or failed open (the page's
/// ring and its words) or a room (rooms are GroupRoomPage, which opens no ChatContext).
/// Not on Windows: the Mac's Talk capsule (no Talk on Windows yet), so it isn't drawn.
internal static class ChatIntroFeature
{
    public static void Register() => ChatExtensions.OnOpen.Add(Attach);

    private static void Attach(ChatContext ctx)
    {
        var view = new IntroView(ctx);
        ctx.TranscriptEmpty.Children.Add(view.Root);
        void Update() => ctx.Page.DispatcherQueue.TryEnqueue(view.Update);
        void Titled(string _) => Update();
        var hub = ListsHub.Current;
        ctx.TranscriptChanged += Update;
        HermesCoreIntro.Changed += Update;
        ctx.Session.TitleChanged += Titled;
        if (hub != null) hub.Changed += Update;   // the roster arrives (or a bot is renamed) after the chat opens
        ctx.Closed += () =>
        {
            ctx.TranscriptChanged -= Update;
            HermesCoreIntro.Changed -= Update;
            ctx.Session.TitleChanged -= Titled;
            if (hub != null) hub.Changed -= Update;
        };
        view.Update();
    }

    private sealed class IntroView
    {
        private readonly ChatContext _ctx;
        public readonly Grid Root = new() { IsHitTestVisible = true };
        private readonly StackPanel _stack = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Spacing = 10, MaxWidth = 520, Margin = new Thickness(24, 0, 24, 40) };
        private readonly BotHead _head = new() { Width = 80, Height = 80, HorizontalAlignment = HorizontalAlignment.Center };
        private readonly TextBlock _title = new() { FontSize = 22, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap };
        private readonly TextBlock _role = new() { FontSize = 14, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxLines = 2 };
        private readonly TextBlock _body = new() { HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap };
        private readonly Button _info = new() { HorizontalAlignment = HorizontalAlignment.Center, CornerRadius = new CornerRadius(16), Padding = new Thickness(18, 8, 18, 8), MinHeight = 36 };
        private readonly HyperlinkButton _name = new() { HorizontalAlignment = HorizontalAlignment.Center, MinHeight = 36 };
        /// [settings] Off: nothing drawn, but not silent.
        private readonly TextBlock _off = new() { Text = HermesCoreIntro.OffLabel, Opacity = 0, IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        public ChatIntroMode Mode { get; private set; } = ChatIntroMode.None;

        public IntroView(ChatContext ctx)
        {
            _ctx = ctx;
            var secondary = ThemeBrushes.Get("TextFillColorSecondaryBrush");
            _role.Foreground = secondary;
            _body.Foreground = secondary;
            AutomationProperties.SetAutomationId(_stack, "chat.intro");
            AutomationProperties.SetAutomationId(_title, "chat.intro.title");
            AutomationProperties.SetAutomationId(_role, "chat.intro.role");
            AutomationProperties.SetAutomationId(_body, "chat.intro.body");
            AutomationProperties.SetAutomationId(_off, "chat.intro.off");
            AutomationProperties.SetName(_off, HermesCoreIntro.OffLabel);
            AutomationProperties.SetAccessibilityView(_head, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            _info.Content = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 6,
                Children = { new FontIcon { Glyph = "\uE946", FontSize = 14 }, new TextBlock { Text = "Bot Info", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold } },
            };
            AutomationProperties.SetAutomationId(_info, "chat.intro.info");
            AutomationProperties.SetName(_info, "Bot Info");
            _info.Click += (_, _) => ShowInfo();
            _name.Content = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 5,
                Children = { new FontIcon { Glyph = "\uE70F", FontSize = 13 }, new TextBlock { Text = "Name Chat" } },
            };
            AutomationProperties.SetAutomationId(_name, "chat.intro.name");
            AutomationProperties.SetName(_name, "Name Chat");
            AutomationProperties.SetHelpText(_name, "Names this chat");
            _name.Click += (_, _) => { AppLog.Note("chatui", "intro Name Chat tapped"); _ = Transcript.TranscriptFeature.RenameAsync(_ctx); };
            foreach (var el in new UIElement[] { _head, _title, _role, _body, _info, _name }) _stack.Children.Add(el);
            // A panel with no background lets clicks through to the transcript; only the two buttons take them.
            Root.Children.Add(_stack);
            Root.Children.Add(_off);
            Root.Visibility = Visibility.Collapsed;
        }

        private BotRowRef? Row() => ListsHub.Current?.Bots.Bot(_ctx.Session.Profile) is { } row ? new BotRowRef(row) : null;

        public void Update()
        {
            var mode = HermesCoreIntro.ModeFor(_ctx.RowCount(), _ctx.HasHiddenRows(), room: false, _ctx.OpenPhase, HermesCoreIntro.IsOn);
            if (mode != Mode) AppLog.Note("chatui", $"intro {Mode} -> {mode}");
            Mode = mode;
            Root.Visibility = mode is ChatIntroMode.Empty or ChatIntroMode.Blank ? Visibility.Visible : Visibility.Collapsed;
            _stack.Visibility = mode == ChatIntroMode.Empty ? Visibility.Visible : Visibility.Collapsed;
            _off.Visibility = mode == ChatIntroMode.Blank ? Visibility.Visible : Visibility.Collapsed;
            if (mode != ChatIntroMode.Empty) return;
            var row = Row();
            var name = HermesCoreIntro.BotName(row?.Name, _ctx.Session.Profile);
            _head.DisplayName = _ctx.Session.Profile;
            _head.Bot = row?.Model;
            _title.Text = name;
            var lines = HermesCoreIntro.Lines(name, row?.Role, row?.About);
            _role.Text = lines.Role ?? "";
            _role.Visibility = lines.Role == null ? Visibility.Collapsed : Visibility.Visible;
            _body.Text = HermesCoreIntro.Body(lines);
            _body.FontSize = lines.About == null ? 14 : 12;
            _body.MaxLines = lines.About == null ? 0 : 4;
            _info.Visibility = row != null && ShellBotActions() != null ? Visibility.Visible : Visibility.Collapsed;
            _name.Visibility = HermesCoreIntro.CanName(_ctx.Session.Title) ? Visibility.Visible : Visibility.Collapsed;
        }

        private static BotActions? ShellBotActions() => Pages.ShellPage.Current?.Actions;

        private void ShowInfo()
        {
            if (ListsHub.Current?.Bots.Bot(_ctx.Session.Profile) is { } row && ShellBotActions() is { } actions)
                _ = actions.ShowInfoAsync(row);
        }
    }

    /// The roster row's parts the intro draws (BotRow; its description is the Mac's `rowDescription`).
    private sealed record BotRowRef(string Name, string? Role, string? About, Hermes.Core.Model.Bot? Model)
    {
        public BotRowRef(Hermes.Core.Bots.BotRow row) : this(row.Name, row.Role, row.Model.Description, row.Model) { }
    }
}
