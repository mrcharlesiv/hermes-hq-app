using Hermes.Core.PhoneCalls;
using HermesHQ.Features.Kanban;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.PhoneCalls;

/// Call History page (`App/PhoneCalls/PhoneHistory.swift` UI counterpart):
/// displays live active call banner, search box, chronological history list, quick Call Again / Copy / Delete,
/// New Call, Settings, and Clear History.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class PhoneHistoryPage : Page
{
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private PhoneCallController _controller = PhoneCallsFeature.GetController();
    private readonly StackPanel _list = new() { Spacing = 6, Padding = new Thickness(16, 8, 16, 24) };
    private readonly TextBox _search = new() { PlaceholderText = "Search calls, numbers, goals", Width = 240, VerticalAlignment = VerticalAlignment.Center };
    private string _query = "";

    public PhoneHistoryPage()
    {
        AutomationProperties.SetName(this, "Phone Calls");
        AutomationProperties.SetAutomationId(this, "phone.history");

        var title = new TextBlock { Text = "Phone Calls", VerticalAlignment = VerticalAlignment.Center };
        PageBar.Title(title, "phone-calls");

        _search.TextChanged += (_, _) => { _query = _search.Text; Render(); };

        var newCallBtn = Push("New Call", () => PhoneCallsFeature.OpenCallWindow(), accent: true);
        AutomationProperties.SetAutomationId(newCallBtn, "phone.history.new");

        var settingsBtn = Quiet("Settings…", () => _ = PhoneCallsFeature.OpenSettingsAsync(XamlRoot));
        var clearBtn = Quiet("Clear History", () => _ = ClearHistoryAsync());
        clearBtn.Foreground = Critical;

        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        tools.Children.Add(_search);
        tools.Children.Add(settingsBtn);
        tools.Children.Add(clearBtn);
        tools.Children.Add(newCallBtn);

        var bar = new Grid { Padding = PageBar.Padding(12, 4), ColumnSpacing = 10 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(title);
        Grid.SetColumn(tools, 1);
        bar.Children.Add(tools);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(bar);
        var scroller = new ScrollViewer
        {
            Content = _list,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        scroller.SizeChanged += (_, _) =>
        {
            if (scroller.ViewportWidth > 0)
                _list.Width = scroller.ViewportWidth;
        };
        Grid.SetRow(scroller, 1);
        root.Children.Add(scroller);
        Content = root;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _controller = PhoneCallsFeature.GetController();
        _controller.Changed += OnChanged;
        Render();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _controller.Changed -= OnChanged;
    }

    private void OnChanged() => _ui.TryEnqueue(Render);

    private void Render()
    {
        _list.Children.Clear();
        var now = DateTimeOffset.UtcNow;

        if (!_controller.IsReady)
        {
            var setup = new Grid { ColumnSpacing = 12 };
            setup.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            setup.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var words = new StackPanel { Spacing = 2 };
            words.Children.Add(Text("Set up Phone Calls", 14, bold: true));
            words.Children.Add(Text("Connect your samplehost account and AI assistant to place phone calls from Hermes.", 13, color: Secondary));
            setup.Children.Add(words);
            var btn = Push("Open Settings…", () => _ = PhoneCallsFeature.OpenSettingsAsync(XamlRoot), accent: true);
            btn.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(btn, 1);
            setup.Children.Add(btn);
            _list.Children.Add(Card(setup, 12));
        }

        if (_controller.ActiveCall is { IsActive: true } active)
        {
            var chip = PhoneChipWords.From(active, now);
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(Dot(chip.NeedsAttention ? Red : Green, 10));
            var info = new StackPanel { Spacing = 2 };
            info.Children.Add(Text($"{active.DisplayTarget} · {chip.Text}", 14, bold: true));
            info.Children.Add(Text(active.Goal, 12, color: Secondary, wrap: false));
            Grid.SetColumn(info, 1);
            row.Children.Add(info);
            var open = Push("Open Call", () => PhoneCallsFeature.OpenCallWindow(callId: active.Id), accent: true);
            Grid.SetColumn(open, 2);
            row.Children.Add(open);
            _list.Children.Add(Card(row, 12));
        }

        var query = _query.Trim();
        var calls = _controller.History
            .Where(c => query.Length == 0
                || c.DisplayTarget.Contains(query, StringComparison.OrdinalIgnoreCase)
                || c.To.Contains(query, StringComparison.OrdinalIgnoreCase)
                || c.Goal.Contains(query, StringComparison.OrdinalIgnoreCase)
                || (c.Summary?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false))
            .ToList();

        if (calls.Count == 0)
        {
            var empty = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(24, 56, 24, 24), MaxWidth = 420 };
            empty.Children.Add(new FontIcon { Glyph = "\uE717", FontSize = 34, Foreground = Tertiary });
            var h = Text(_controller.History.Count == 0 ? "No Phone Calls Yet" : "No Matching Calls", 17, bold: true);
            h.TextAlignment = TextAlignment.Center;
            empty.Children.Add(h);
            var sub = Text(_controller.History.Count == 0
                ? "Your outbound AI phone calls, summaries, and transcripts will appear here."
                : "Try a different search term.", 13, color: Secondary);
            sub.TextAlignment = TextAlignment.Center;
            empty.Children.Add(sub);
            _list.Children.Add(empty);
            return;
        }

        foreach (var call in calls)
            _list.Children.Add(CallRow(call, now));
    }

    private FrameworkElement CallRow(PhoneCallRecord call, DateTimeOffset now)
    {
        var outcome = call.Outcome ?? PhoneOutcome.Unknown;
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        grid.Children.Add(Dot(OutcomeColor(outcome), 10));

        var center = new StackPanel { Spacing = 2 };
        var top = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        top.Children.Add(Text(call.DisplayTarget, 14, bold: true, wrap: false));
        top.Children.Add(Text(PhoneFormatting.OutcomeTitle(outcome, call.LocalEnd), 12, color: Secondary, wrap: false));
        center.Children.Add(top);
        center.Children.Add(Text(PhoneCallPresentation.WhatHappened(call), 12, color: Secondary, wrap: false));
        Grid.SetColumn(center, 1);
        grid.Children.Add(center);

        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        if (call.AnsweredAt != null)
            trailing.Children.Add(Text(PhoneFormatting.FormatDuration(call.Elapsed(now)), 12, color: Secondary, wrap: false));
        trailing.Children.Add(Text(call.StartedAt.ToLocalTime().ToString("MMM d, h:mm tt"), 12, color: Tertiary, wrap: false));
        Grid.SetColumn(trailing, 2);
        grid.Children.Add(trailing);

        var card = Card(grid, 10);
        card.Tapped += (_, _) => PhoneCallsFeature.OpenCallWindow(callId: call.Id);

        var menu = new MenuFlyout();
        var openItem = new MenuFlyoutItem { Text = "Open Details", Icon = new FontIcon { Glyph = "\uE8A7" } };
        openItem.Click += (_, _) => PhoneCallsFeature.OpenCallWindow(callId: call.Id);
        var againItem = new MenuFlyoutItem { Text = "Call Again", Icon = new FontIcon { Glyph = "\uE717" } };
        againItem.Click += (_, _) => PhoneCallsFeature.OpenCallWindow(
            new PhoneStartIntent(call.To, call.Goal, call.TargetName, call.Voicemail), startInReview: true);
        var copyItem = new MenuFlyoutItem { Text = "Copy Summary & Transcript", Icon = new FontIcon { Glyph = "\uE8C8" } };
        copyItem.Click += (_, _) => Copy(PhoneCallPresentation.ShareText(call, PhoneCallsFeature.KeyStore.ReadKey(_controller.AccountId)));
        var delItem = new MenuFlyoutItem { Text = "Delete", Icon = new FontIcon { Glyph = "\uE74D" }, Foreground = Critical };
        delItem.Click += (_, _) => _controller.DeleteCall(call.Id);
        menu.Items.Add(openItem);
        menu.Items.Add(againItem);
        menu.Items.Add(copyItem);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(delItem);
        card.ContextFlyout = menu;
        return card;
    }

    private async Task ClearHistoryAsync()
    {
        if (_controller.History.Count == 0) return;
        if (!await ConfirmAsync(XamlRoot, "Clear Phone Call History?", "All saved phone call summaries and transcripts for this account will be deleted.", "Clear History"))
            return;
        _controller.ClearHistory();
    }

    private static Color OutcomeColor(PhoneOutcome outcome) => outcome.Kind switch
    {
        PhoneOutcomeKind.Finished => Green,
        PhoneOutcomeKind.Voicemail or PhoneOutcomeKind.NoAnswer or PhoneOutcomeKind.Busy => Orange,
        PhoneOutcomeKind.Declined or PhoneOutcomeKind.NoSuchNumber or PhoneOutcomeKind.CouldNotConnect => Red,
        _ => Rgb(0x8E, 0x8E, 0x93),
    };
}
