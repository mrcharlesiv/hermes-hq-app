using System.Text.Json.Nodes;
using Hermes.Core.Activity;
using Hermes.Core.Chat;
using Hermes.Core.Net;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Transcript;

/// The shelf above the message box (App/Chat/Activity/ActivityShelfView.swift, ShelfBodies.swift, SubagentBodies.swift):
/// one card whose header reads the chips ("Tasks 2/5 · 1 helper · Goal active · Turn 3/20"), opening on the task list,
/// each helper (with Steer and Stop) and the goal (with its menu).
public sealed class ActivityShelf
{
    private readonly ChatSession _session;
    private readonly ActivityStore _store;
    private readonly BackgroundTasksPanel _backgroundPanel;
    private readonly Border _card = new();
    private bool _open = true;
    private bool _backgroundOpen;
    private string? _lastKey;
    private static readonly Dictionary<string, string> SteerDrafts = [];

    public FrameworkElement View => _card;

    /// Running background processes panel hosted inside the `"Background"` shelf piece.
    public BackgroundTasksPanel BackgroundPanel => _backgroundPanel;

    public ActivityShelf(ChatSession session, ActivityStore store)
    {
        _session = session;
        _store = store;
        _backgroundPanel = new BackgroundTasksPanel(session, store);
        _backgroundPanel.ProcessesChanged += () => Refresh(force: true);
        _card.Padding = new Thickness(12, 8, 12, 8);
        _card.CornerRadius = new CornerRadius(10);
        _card.Background = Res<Brush>("HQPromptCardBrush");
        _card.BorderBrush = Res<Brush>("HQPromptEdgeBrush");
        _card.BorderThickness = new Thickness(1);
        _card.Visibility = Visibility.Collapsed;
        _card.Loaded += (_, _) => _backgroundPanel.SetAttached(true);
        _card.Unloaded += (_, _) => _backgroundPanel.SetAttached(false);
    }

    /// Redraws from the store's snapshot and active background tasks; hidden while there is nothing to show.
    public void Refresh(bool force = false)
    {
        var a = _store.Snapshot;
        var bg = _backgroundPanel.RunningProcesses;
        if (_card.IsLoaded && (_session.Busy || bg.Count > 0)) _backgroundPanel.EnsurePolling();
        if (bg.Count == 0) _backgroundOpen = false;

        if (a.IsEmpty && bg.Count == 0)
        {
            _lastKey = null;
            UiTree.DetachFromParent(_backgroundPanel);
            UiTree.DeactivateProgressRings(_card);
            _card.Visibility = Visibility.Collapsed;
            _card.Child = null;
            return;
        }
        var todos = a.LiveTodos ?? a.RetainedTodos;
        var key = $"{_open}|{_backgroundOpen}|{a.HasLiveSubagents}|{a.Control.PendingAction}|{a.Goal?.Title}|{a.Goal?.Status}|"
            + $"{string.Join(";", todos.Select(t => $"{t.Status}:{t.Content}"))}|"
            + $"{string.Join(";", a.Subagents.Select(c => $"{c.Id}:{(int)c.Status}:{c.Goal}:{SubagentWords.RowLine(c)}"))}|"
            + $"{string.Join(";", bg.Select(b => $"{b.Id}:{b.Headline}:{b.StatusLine}"))}";
        if (!force && key == _lastKey && _card.Child != null) return;
        _lastKey = key;

        _card.Visibility = Visibility.Visible;
        var chips = new List<string>();
        if (a.LiveTodos is { } live) chips.Add(TodoRules.ChipWords(live, false));
        else if (a.RetainedTodos.Count > 0) chips.Add(TodoRules.ChipWords(a.RetainedTodos, true));
        if (a.Subagents.Count > 0)
            chips.Add(a.HasLiveSubagents ? SubagentRules.ChipWords(a.LiveSubagents.Count) : SubagentWords.CountLine(a.Subagents));
        if (bg.Count > 0 && BackgroundProcess.FormatChipWords(bg) is { } bgChip)
            chips.Add(bgChip);
        if (a.Goal is { } goal) chips.Add(ControlRules.ChipWords(goal));

        UiTree.DetachFromParent(_backgroundPanel);
        UiTree.DeactivateProgressRings(_card);

        var stack = new StackPanel { Spacing = 6 };
        var header = new Button
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
        };
        var headRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (a.HasLiveSubagents || bg.Count > 0) headRow.Children.Add(new ProgressRing { IsActive = true, Width = 12, Height = 12 });
        headRow.Children.Add(new TextBlock { Text = string.Join(" · ", chips), FontSize = 12.5, FontWeight = FontWeights.SemiBold });
        headRow.Children.Add(new FontIcon { Glyph = _open ? "" : "", FontSize = 9 });
        header.Content = headRow;
        header.Click += (_, _) => { _open = !_open; Refresh(force: true); };
        stack.Children.Add(header);
        if (_open)
        {
            foreach (var t in todos) stack.Children.Add(TodoRow(t));
            if (a.Subagents.Count > 1)
                stack.Children.Add(HelperStatusRows.BuildDisclosureRow(_session, a.Subagents, _store));
            foreach (var child in a.Subagents) stack.Children.Add(HelperRow(_session, child, compact: true, _store));
            if (bg.Count > 0)
            {
                stack.Children.Add(BackgroundPiece(bg));
                if (_backgroundOpen)
                {
                    _backgroundPanel.Rebuild();
                    stack.Children.Add(_backgroundPanel);
                }
            }
            if (a.Goal is { } g) stack.Children.Add(GoalRow(g, a.Control.PendingAction != null));
        }
        _card.Child = stack;
    }

    /// The `"Background"` shelf piece header showing running count and active chip; clicking toggles `BackgroundTasksPanel`.
    private FrameworkElement BackgroundPiece(IReadOnlyList<BackgroundProcess> running)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        grid.Children.Add(new ProgressRing { IsActive = true, Width = 12, Height = 12, VerticalAlignment = VerticalAlignment.Center });

        var label = new TextBlock
        {
            Text = "Background",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(label, 1);
        grid.Children.Add(label);

        var count = new TextBlock
        {
            Text = $"{running.Count} running",
            FontSize = 12,
            Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(count, 2);
        grid.Children.Add(count);

        var chevron = new FontIcon
        {
            Glyph = _backgroundOpen ? "\uE70E" : "\uE70D",
            FontSize = 10,
            Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(chevron, 3);
        grid.Children.Add(chevron);

        var piece = new Button
        {
            Content = grid,
            Background = Res<Brush>("SubtleFillColorSecondaryBrush"),
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 6, 10, 6),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(piece, "chat.shelf.background");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(piece, BackgroundProcess.FormatChipWords(running) ?? "Background task");
        piece.Click += (_, _) =>
        {
            _backgroundOpen = !_backgroundOpen;
            Refresh(force: true);
        };
        return piece;
    }

    private static FrameworkElement TodoRow(TodoItem t)
    {
        var glyph = t.Status switch
        {
            TodoStatus.Completed => "", TodoStatus.InProgress => "", TodoStatus.Cancelled => "", _ => "",
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(t.Parent == null ? 0 : 18, 0, 0, 0) };
        row.Children.Add(new FontIcon { Glyph = glyph, FontSize = 12, Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        var text = new TextBlock { Text = t.Content, FontSize = 13, TextWrapping = TextWrapping.Wrap };
        if (t.Status is TodoStatus.Completed or TodoStatus.Cancelled)
        {
            text.Foreground = Res<Brush>("TextFillColorTertiaryBrush");
            text.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
        }
        row.Children.Add(text);
        return row;
    }

    /// One helper: its goal, status and timer, its newest step; clicking opens `HelperStatusRows.ShowTailDialogAsync`;
    /// while it runs, Steer (a box) and Stop.
    internal static FrameworkElement HelperRow(ChatSession session, SubagentProgress child, bool compact, ActivityStore? store = null)
    {
        var stack = new StackPanel { Spacing = 2 };
        var top = new Grid();
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titleBtn = new Button
        {
            Content = new TextBlock { Text = child.Goal, FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis },
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
        };
        titleBtn.Click += async (_, _) => await HelperStatusRows.ShowTailDialogAsync(titleBtn.XamlRoot, session, child, store);
        top.Children.Add(titleBtn);
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        var status = new TextBlock
        {
            Text = $"{SubagentWords.Status(child.Status)} · {SubagentWords.Timer(child, now)}", FontSize = 12,
            Foreground = Res<Brush>(child.Status == SubagentStatus.Failed ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"),
        };
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        right.Children.Add(status);
        var detailsBtn = new Button
        {
            Content = "Details", FontSize = 11, Padding = new Thickness(8, 2, 8, 2),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(1),
            BorderBrush = Res<Brush>("CardStrokeColorDefaultBrush"), CornerRadius = new CornerRadius(6),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(detailsBtn, "activity.helper.details." + child.Id);
        detailsBtn.Click += async (_, _) => await HelperStatusRows.ShowTailDialogAsync(detailsBtn.XamlRoot, session, child, store);
        right.Children.Add(detailsBtn);
        Grid.SetColumn(right, 1);
        top.Children.Add(right);
        stack.Children.Add(top);
        stack.Children.Add(new TextBlock
        {
            Text = SubagentWords.RowLine(child), FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = compact ? 1 : 3,
            TextWrapping = TextWrapping.Wrap, Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
        });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(stack, SubagentWords.RowAccessibilityLabel(child));
        if (child.IsLive && session.RuntimeId is { } runtime)
        {
            var note = new TextBlock { FontSize = 11, Foreground = Res<Brush>("TextFillColorTertiaryBrush"), Visibility = Visibility.Collapsed };
            var steerRow = new Grid { ColumnSpacing = 6, Margin = new Thickness(0, 4, 0, 0) };
            steerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            steerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            steerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var box = new TextBox
            {
                PlaceholderText = SubagentWords.SteerPlaceholder, FontSize = 12,
                Text = SteerDrafts.TryGetValue(child.Id, out var savedDraft) ? savedDraft : "",
            };
            box.TextChanged += (_, _) => SteerDrafts[child.Id] = box.Text;
            var steer = new Button { Content = SubagentWords.Steer, FontSize = 12 };
            var stop = new Button { Content = SubagentWords.Stop, FontSize = 12 };
            Grid.SetColumn(steer, 1);
            Grid.SetColumn(stop, 2);
            steerRow.Children.Add(box);
            steerRow.Children.Add(steer);
            steerRow.Children.Add(stop);
            steer.Click += async (_, _) =>
            {
                if (ActivityStore.Steer(runtime, session.Profile, child.Id, box.Text) is not { } req) return;
                try
                {
                    var answer = await session.CallAsync(req.Method, req.Params, ActivityStore.ReadTimeout);
                    var queued = ActivityStore.ReadSteer(answer) == SteerOutcome.Queued;
                    note.Text = queued ? SubagentWords.SteerQueued : SubagentWords.Rejected;
                    if (queued) { SteerDrafts.Remove(child.Id); box.Text = ""; }
                }
                catch (GatewayException x) { note.Text = x.Message; }
                note.Visibility = Visibility.Visible;
            };
            stop.Click += async (_, _) =>
            {
                var req = ActivityStore.StopChild(runtime, session.Profile, child.Id);
                try
                {
                    var answer = await session.CallAsync(req.Method, req.Params, ActivityStore.ReadTimeout);
                    if (ActivityStore.ReadInterrupt(answer)) { note.Text = SubagentWords.StopRequested; note.Visibility = Visibility.Visible; }
                }
                catch (GatewayException x) { note.Text = x.Message; note.Visibility = Visibility.Visible; }
            };
            stack.Children.Add(steerRow);
            stack.Children.Add(note);
        }
        return new Border
        {
            Child = stack, Padding = new Thickness(10, 6, 10, 6), CornerRadius = new CornerRadius(8),
            Background = Res<Brush>("SubtleFillColorSecondaryBrush"),
        };
    }

    /// The goal: its title and state, and its ⋯ menu (Pause / Resume / Resume Now / Clear Goal…).
    private FrameworkElement GoalRow(GoalSnapshot goal, bool pending)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new StackPanel();
        words.Children.Add(new TextBlock { Text = goal.Title, FontSize = 13, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        words.Children.Add(new TextBlock { Text = ControlRules.ChipWords(goal), FontSize = 12, Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        grid.Children.Add(words);
        var menu = new MenuFlyout();
        foreach (var item in GoalWords.Menu(goal))
        {
            var entry = new MenuFlyoutItem { Text = item.Title, IsEnabled = !pending && item.Action != null };
            if (item.Destructive) entry.Foreground = Res<Brush>("SystemFillColorCriticalBrush");
            var action = item.Action;
            var confirm = item.Confirm;
            entry.Click += async (_, _) =>
            {
                if (action == null) return;
                if (confirm != null && _card.XamlRoot != null)
                {
                    var ask = new ContentDialog
                    {
                        Title = confirm.Title, Content = confirm.Message, PrimaryButtonText = confirm.Action, CloseButtonText = "Cancel",
                    };
                    if (await SafeDialog.ShowAsync(_card.XamlRoot, ask) != ContentDialogResult.Primary) return;
                }
                await RunGoalAction(action);
            };
            menu.Items.Add(entry);
        }
        var more = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, Flyout = menu, Padding = new Thickness(6, 4, 6, 4) };
        // [WIN-55] ActivityShelfView.swift: `more.accessibilityLabel = "Goal Actions"`.
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(more, "Goal Actions");
        Grid.SetColumn(more, 1);
        grid.Children.Add(more);
        return grid;
    }

    private async Task RunGoalAction(string action)
    {
        if (_store.Control(action) is not { } req) return;
        _store.BeginControl(action);
        Refresh();
        try { _store.EndControl(await _session.CallAsync(req.Method, req.Params, ActivityStore.ReadTimeout)); }
        catch (GatewayException x) { _store.FailControl(x.Message); AppLog.Note("activity", $"goal action failed: {x.Code}"); }
        Refresh();
    }

    private static T Res<T>(string key) => ThemeBrushes.Res<T>(key);
}
