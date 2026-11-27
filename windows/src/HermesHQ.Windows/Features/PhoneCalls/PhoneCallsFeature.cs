using Hermes.Core.Composer;
using Hermes.Core.PhoneCalls;
using HermesHQ.Features.Kanban;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.PhoneCalls;

/// Entry points for Phone Calls: place registration, chat chip, proposal/result cards, call window, history, and settings.
/// Hook `PhoneCallsFeature.Register()` from `FeatureRegistry.RegisterAll()`.
public static class PhoneCallsFeature
{
    public const string HistoryPlaceId = "phone-calls";

    private static bool _registered;
    private static readonly samplehostApi SharedApi = new();
    private static readonly IPhoneKeyStore SharedKeys = Automation.AppOnly || Automation.Enabled ? new MemoryPhoneKeyStore() : new WindowsPhoneKeyStore();
    private static readonly FilePhoneHistoryStore SharedHistory = new(AppPaths.Root);
    private static readonly JsonFileStore SharedSetupStore = new(System.IO.Path.Combine(AppPaths.Root, "phone-setup.json"));
    private static string? _controllerAccount;
    private static PhoneCallController? _controller;

    /// Registers Phone Calls history page and chat hooks (live call chip, composer note, ⋯ menu, result delivery).
    public static void Register()
    {
        if (_registered) return;
        _registered = true;

        var existing = Places.All.FirstOrDefault(p => p.Id == HistoryPlaceId);
        if (existing != null) existing.Page = typeof(PhoneHistoryPage);
        else Places.All.Add(new Place(HistoryPlaceId, "Phone Calls", "\uE717", Places.Tools, typeof(PhoneHistoryPage),
            ["phone", "calls", "samplehost", "voice", "dial", "voicemail"]));

        AppState.ClientChanged += OnClientChanged;

        ChatExtensions.OnOpen.Add(AttachToChat);
    }

    private static void OnClientChanged(Hermes.Core.HermesClient? client)
    {
        PhoneCallWindow.CloseOpen();
        var old = _controller;
        _controller = null;
        _controllerAccount = null;
        if (old != null) _ = old.EndAllAsync();
    }

    internal static void CloseForQuit()
    {
        AppState.ClientChanged -= OnClientChanged;
        PhoneCallWindow.CloseOpen();
        var old = _controller;
        _controller = null;
        _controllerAccount = null;
        if (old != null) _ = old.EndAllAsync();
    }

    /// Returns the active account's `PhoneCallController`.
    public static PhoneCallController GetController()
    {
        var accountId = AppState.Client?.AccountId ?? "local";
        if (_controller != null && _controllerAccount == accountId) return _controller;
        _controller = new PhoneCallController(accountId, SharedApi, SharedKeys, SharedHistory, SharedSetupStore);
        _controllerAccount = accountId;
        return _controller;
    }

    internal static IsamplehostApi Api => SharedApi;
    internal static IPhoneKeyStore KeyStore => SharedKeys;

    public static void OpenHistoryPage() => Navigator.Open(HistoryPlaceId);

    public static void OpenCallWindow(PhoneStartIntent? prefill = null, string? callId = null, bool startInReview = false) =>
        PhoneCallWindow.Show(GetController(), prefill, callId, startInReview);

    public static Task OpenSettingsAsync(XamlRoot? root) =>
        PhoneSettingsDialog.PresentAsync(root, GetController(), SharedApi, SharedKeys);

    /// Handles a `hermes://phone-call?...` URI clicked inside a chat message.
    public static bool TryHandleProposalUri(string uri, bool fromChat = true, string? chatProfile = null, string? chatSessionId = null)
    {
        if (PhoneProposal.TryParse(uri, fromChat) is not { } proposal) return false;
        OpenCallWindow(new PhoneStartIntent(
            To: proposal.To,
            Goal: proposal.Goal,
            TargetName: proposal.Name,
            Voicemail: proposal.Voicemail,
            ChatProfile: chatProfile,
            ChatSessionId: chatSessionId), startInReview: true);
        return true;
    }

    /// Builds a live in-chat phone call status chip (`PhoneChatChip.swift` port).
    public static FrameworkElement BuildChatChip(PhoneCallController? controller = null) =>
        new PhoneChatChipControl(controller ?? GetController());

    /// Builds an in-chat call proposal card (`PhoneChatCards.swift` port).
    public static FrameworkElement BuildProposalCard(PhoneProposal proposal, string? chatProfile = null, string? chatSessionId = null)
    {
        var stack = new StackPanel { Spacing = 6 };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        head.Children.Add(new FontIcon { Glyph = "\uE717", FontSize = 15, Foreground = Accent });
        head.Children.Add(Text(string.IsNullOrWhiteSpace(proposal.Name) ? PhoneFormatting.FormatShown(proposal.To) : proposal.Name!, 14, bold: true));
        stack.Children.Add(head);

        if (!string.IsNullOrWhiteSpace(proposal.Name))
            stack.Children.Add(Text(PhoneFormatting.FormatShown(proposal.To), 12, color: Secondary));

        stack.Children.Add(Text(proposal.Goal, 13));

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 4, 0, 0) };
        actions.Children.Add(Push("Review & Call", () =>
        {
            OpenCallWindow(new PhoneStartIntent(
                To: proposal.To,
                Goal: proposal.Goal,
                TargetName: proposal.Name,
                Voicemail: proposal.Voicemail,
                ChatProfile: chatProfile,
                ChatSessionId: chatSessionId), startInReview: true);
        }, accent: true));
        stack.Children.Add(actions);

        var card = Card(stack, 12);
        AutomationProperties.SetAutomationId(card, "phone.proposal-card");
        return card;
    }

    /// Builds an in-chat finished call summary card (`PhoneChatCards.swift` port).
    public static FrameworkElement BuildResultCard(PhoneResultCard result, string? callId = null)
    {
        var stack = new StackPanel { Spacing = 4 };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        head.Children.Add(new FontIcon { Glyph = "\uE717", FontSize = 14, Foreground = Secondary });
        head.Children.Add(Text(result.Target, 14, bold: true));
        stack.Children.Add(head);
        if (!string.IsNullOrEmpty(result.OutcomeLine))
            stack.Children.Add(Text(result.OutcomeLine, 12, bold: true, color: Secondary));
        if (!string.IsNullOrEmpty(result.Summary))
            stack.Children.Add(Text(result.Summary, 13));
        else if (!string.IsNullOrEmpty(result.Goal))
            stack.Children.Add(Text(result.Goal, 13, color: Secondary));

        var openBtn = Quiet("Open Call History", () =>
        {
            if (!string.IsNullOrEmpty(callId)) OpenCallWindow(callId: callId);
            else OpenHistoryPage();
        });
        openBtn.HorizontalAlignment = HorizontalAlignment.Left;
        stack.Children.Add(openBtn);

        var card = Card(stack, 12);
        AutomationProperties.SetAutomationId(card, "phone.result-card");
        return card;
    }

    private static void AttachToChat(ChatContext ctx)
    {
        var controller = GetController();
        var chip = new PhoneChatChipControl(controller);
        ctx.Shelf.Children.Add(chip);

        // Chat ⋯ menu entries
        var callItem = new MenuFlyoutItem { Text = "Place Phone Call…", Icon = new FontIcon { Glyph = "\uE717" } };
        callItem.Click += (_, _) => OpenCallWindow(new PhoneStartIntent("", "", ChatProfile: ctx.Session.Profile, ChatSessionId: ctx.Session.StoredId));
        ctx.MoreMenu.Items.Add(callItem);

        var historyItem = new MenuFlyoutItem { Text = "Phone Call History", Icon = new FontIcon { Glyph = "\uE81C" } };
        historyItem.Click += (_, _) => OpenHistoryPage();
        ctx.MoreMenu.Items.Add(historyItem);

        var settingsItem = new MenuFlyoutItem { Text = "Phone Settings…", Icon = new FontIcon { Glyph = "\uE713" } };
        settingsItem.Click += (_, _) => _ = OpenSettingsAsync(ctx.Page.XamlRoot);
        ctx.MoreMenu.Items.Add(settingsItem);

        void OnControllerChanged()
        {
            _ = controller.DeliverPendingResultsAsync(async (profile, sessionId, message) =>
            {
                if (!string.Equals(profile, ctx.Session.Profile, StringComparison.Ordinal)
                    || !string.Equals(sessionId, ctx.Session.StoredId, StringComparison.Ordinal))
                    return false;
                var outcome = await ctx.Session.SendAsync(message);
                return outcome != Hermes.Core.Chat.SendOutcome.Refused;
            });
        }
        controller.Changed += OnControllerChanged;

        ctx.Closed += () =>
        {
            controller.Changed -= OnControllerChanged;
            chip.Dispose();
            ctx.Shelf.Children.Remove(chip);
        };
    }

    private sealed class PhoneChatChipControl : UserControl, IDisposable
    {
        private readonly PhoneCallController _controller;
        private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
        private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
        private readonly Border _frame;
        private readonly TextBlock _label = Text("", 13, bold: true, wrap: false);
        private readonly Microsoft.UI.Xaml.Shapes.Ellipse _dot = Dot(Green, 8);
        private string? _callId;
        private bool _disposed;

        public PhoneChatChipControl(PhoneCallController controller)
        {
            _controller = controller;
            Margin = new Thickness(0, 0, 0, 6);
            HorizontalAlignment = HorizontalAlignment.Left;
            Visibility = Visibility.Collapsed;
            AutomationProperties.SetAutomationId(this, "phone.chat-chip");

            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            row.Children.Add(_dot);
            row.Children.Add(_label);
            row.Children.Add(Text("Open ›", 12, color: Secondary, wrap: false));
            _frame = new Border
            {
                CornerRadius = new CornerRadius(16),
                Padding = new Thickness(12, 6, 12, 6),
                BorderThickness = new Thickness(1),
                Child = row,
            };
            Content = _frame;

            Tapped += (_, _) => PhoneCallWindow.Show(_controller, callId: _callId);
            _controller.Changed += OnChanged;
            _timer.Tick += (_, _) => Refresh();
            Refresh();
        }

        private void OnChanged()
        {
            if (_disposed || AppShutdown.Stopping) return;
            _ui.TryEnqueue(Refresh);
        }

        private void Refresh()
        {
            if (_disposed || AppShutdown.Stopping) return;
            var state = PhoneChipWords.From(_controller.ActiveCall, DateTimeOffset.UtcNow);
            Visibility = state.Visible ? Visibility.Visible : Visibility.Collapsed;
            _callId = state.CallId;
            if (!state.Visible)
            {
                _timer.Stop();
                return;
            }
            if (!_timer.IsEnabled) _timer.Start();
            _label.Text = state.Text;
            var color = state.NeedsAttention ? Red : state.IsLive ? Green : Blue;
            _dot.Fill = Solid(color);
            _frame.Background = new SolidColorBrush(Color.FromArgb(26, color.R, color.G, color.B));
            _frame.BorderBrush = Solid(color);
            _frame.BorderThickness = new Thickness(1);
            AutomationProperties.SetName(this, state.Text);
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _timer.Stop();
            _controller.Changed -= OnChanged;
        }
    }
}
