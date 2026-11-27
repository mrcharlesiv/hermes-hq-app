using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// Tasks (App/Pages/Tasks/TasksViewController.swift; docs/tasks.md): the shared to-do list of you and your bots, kept by
/// the Hermes HQ add-on. "Tasks" with New Task and Search at the bar's end; a row of pills (Today, Upcoming, Inbox, each
/// of your lists, Bots once a bot has a task of its own) picks the view; each view's groups ("Today 6", "Waiting on
/// You 4", "Next in Work 3"); a row is the circle that ticks it off, the title with its steps, when it's due and the
/// bot's face, and under it what a bot has for you. A click opens the task beside the list (TaskPane).
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class TasksPage : Page, IKeyRefreshing
{
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    private TasksStore? _store;
    private TaskIdeasStore? _ideasStore;
    private readonly HashSet<string> _expandedIdeas = [];
    private TodoView _view = TodoView.Today;

    /// View › Refresh (Ctrl+R, F5): as its own Ctrl+R and F5.
    public void KeyRefresh() => _ = _store?.RefreshAsync(force: true);
    private string _query = "";
    private string? _selected;
    private bool _doneOpen;
    private readonly StackPanel _pills = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly StackPanel _list = new() { Spacing = 2, Padding = new Thickness(16, 4, 16, 24) };
    private readonly TextBox _search = new() { PlaceholderText = TasksCopy.SearchPlaceholder, Width = 220, VerticalAlignment = VerticalAlignment.Center };
    private readonly ContentControl _paneHost = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly Border _pane;
    private readonly NoticeLine _notice = new();
    private TaskPane? _taskPane;
    private GoalDetailPane? _goalPane;
    private string? _selectedGoal;
    /// The bar's +: New Task, or New Goal in Goals ("Update Add-on" on an older add-on), as screen readers hear it.
    private readonly Button _add = new() { Content = new FontIcon { Glyph = "", FontSize = Hermes.Core.Shell.DesktopLook.BarGlyph }, Style = Style("QuietButtonStyle") };
    /// Select (⋯ › Select Tasks, or Select in a row's menu): the picks and the bar that replaces the page's buttons.
    private readonly TodoSelection _selection = new();
    private readonly StackPanel _tools = new() { Orientation = Orientation.Horizontal, Spacing = 4 };
    private readonly StackPanel _selectBar = new() { Orientation = Orientation.Horizontal, Spacing = 4, Visibility = Visibility.Collapsed };
    private readonly DropDownButton _selectMove = new() { Content = TasksCopy.MoveTo };
    private readonly Button _selectDone = new() { Content = TasksCopy.MarkDone };
    private readonly Button _selectDelete = new() { Content = TasksCopy.Delete };
    /// A list's open rows as shown, top to bottom (where a dragged task lands), and the task being dragged.
    private List<string> _openIds = [];
    private string? _dragging;
    /// Where the held task would land (TasksViewController `dropPlace`), and the line that shows it.
    private readonly TodoDropPlace _dropPlace = new();
    private Rectangle? _dropMark;
    private CancellationTokenSource? _poll;
    private static readonly TimeZoneInfo Zone = TimeZoneInfo.Local;

    public TasksPage()
    {
        AutomationProperties.SetName(this, TasksCopy.Title);
        var title = new TextBlock { Text = TasksCopy.Title, VerticalAlignment = VerticalAlignment.Center };
        HermesHQ.Shell.PageBar.Title(title, "tasks");   // [WIN-49] the Mac's page-title token (MacWindow.pageBar)
        var add = _add;
        AutomationProperties.SetName(add, TasksCopy.NewTask);
        AutomationProperties.SetAutomationId(add, "tasks.new");
        ToolTipService.SetToolTip(add, TasksCopy.NewTask);
        add.Click += (_, _) => NewTask();
        _search.TextChanged += (_, _) => { _query = _search.Text; Render(); };
        AutomationProperties.SetName(_search, TasksCopy.SearchPlaceholder);
        AutomationProperties.SetAutomationId(_search, "tasks.search");   // [WIN-49] the magnifier's field, at the bar's edge
        var bar = new Grid { Padding = HermesHQ.Shell.PageBar.Padding(12, 4), ColumnSpacing = 10 };   // [WIN-49] the page's side
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(title);
        // ⋯ (the Mac's Filter / ⋯ menu): Sort By in a list, then Select Tasks.
        var more = new Button { Content = new FontIcon { Glyph = "\uE712", FontSize = Hermes.Core.Shell.DesktopLook.BarGlyph }, Style = Style("QuietButtonStyle") };
        AutomationProperties.SetName(more, "More");
        AutomationProperties.SetAutomationId(more, "tasks.more");
        ToolTipService.SetToolTip(more, "More");
        var moreMenu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
        moreMenu.Opening += (_, _) => FillMoreMenu(moreMenu);
        more.Flyout = moreMenu;
        _tools.Children.Add(more);
        _tools.Children.Add(add);
        _tools.Children.Add(_search);
        // Select's bar: Move To, Mark Done, Delete, then Done (the Mac's right-hand items, read left to right).
        AutomationProperties.SetAutomationId(_selectMove, "tasks.select.move");
        _selectMove.Flyout = new MenuFlyout();
        ((MenuFlyout)_selectMove.Flyout).Opening += (_, _) => FillSelectMove((MenuFlyout)_selectMove.Flyout);
        AutomationProperties.SetAutomationId(_selectDone, "tasks.select.mark-done");
        _selectDone.Click += (_, _) => MarkSelectedDone();
        AutomationProperties.SetAutomationId(_selectDelete, "tasks.select.delete");
        _selectDelete.Foreground = Critical;
        _selectDelete.Click += (_, _) => _ = DeleteSelectedAsync();
        var endSelect = new Button { Content = TasksCopy.Done, Style = Style("AccentButtonStyle") };
        AutomationProperties.SetAutomationId(endSelect, "tasks.select.done");
        endSelect.Click += (_, _) => SetSelecting(false);
        _selectBar.Children.Add(_selectMove);
        _selectBar.Children.Add(_selectDone);
        _selectBar.Children.Add(_selectDelete);
        _selectBar.Children.Add(endSelect);
        var ends = new Grid();
        ends.Children.Add(_tools);
        ends.Children.Add(_selectBar);
        Grid.SetColumn(ends, 1);
        bar.Children.Add(ends);
        AutomationProperties.SetName(_pills, "Views");
        var pills = new ScrollViewer
        {
            Content = _pills, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollMode = ScrollMode.Disabled, Padding = new Thickness(16, 4, 16, 8),
        };
        var listScroll = new ScrollViewer { Content = _list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        var left = new Grid();
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        left.Children.Add(bar);
        Grid.SetRow(pills, 1);
        left.Children.Add(pills);
        Grid.SetRow(listScroll, 2);
        left.Children.Add(listScroll);
        Grid.SetRow(_notice.Bar, 2);
        left.Children.Add(_notice.Bar);
        _pane = new Border
        {
            Width = 440, Visibility = Visibility.Collapsed, Child = _paneHost, BorderThickness = new Thickness(1, 0, 0, 0),
            BorderBrush = Brush("DividerStrokeColorDefaultBrush"), Background = Brush("LayerFillColorDefaultBrush"),
        };
        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.Children.Add(left);
        Grid.SetColumn(_pane, 1);
        root.Children.Add(_pane);
        Content = root;
        Accelerator(VirtualKey.F5, VirtualKeyModifiers.None, () => _ = _store?.RefreshAsync(force: true));
        Accelerator(VirtualKey.R, VirtualKeyModifiers.Control, () => _ = _store?.RefreshAsync(force: true));
        Accelerator(VirtualKey.F, VirtualKeyModifiers.Control, () => _search.Focus(FocusState.Keyboard));
        // Esc while selecting does nothing (the Mac keeps Select and its picks); otherwise it closes the task beside the list.
        Accelerator(VirtualKey.Escape, VirtualKeyModifiers.None, () => { if (_selection.OnEscape() == TodoSelection.EscapeAction.CloseTask) CloseTask(); });
    }

    private void Accelerator(VirtualKey key, VirtualKeyModifiers mods, Action run)
    {
        var a = new KeyboardAccelerator { Key = key, Modifiers = mods };
        a.Invoked += (_, e) => { e.Handled = true; run(); };
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        KeyboardAccelerators.Add(a);
    }

    private void OnStoreNotice(string text, string? _) => _ui.TryEnqueue(() => { if (!AppShutdown.Stopping) _notice.Show(text); });
    private void OnIdeaNotice(string text) => _ui.TryEnqueue(() => { if (!AppShutdown.Stopping) _notice.Show(text); });

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (AppState.Client is not { } client) return;
        var api = new TasksApi(new GatewaySessionRest(client.Session));
        _store = new TasksStore(api);
        _store.Changed += OnChanged;
        _store.Notice += OnStoreNotice;
        _ideasStore = new TaskIdeasStore(api);
        _ideasStore.Changed += OnChanged;
        _ideasStore.Notice += OnIdeaNotice;
        Render();
        var cts = _poll = new CancellationTokenSource();
        _ = PollAsync(cts.Token);
        _ = _ideasStore.RefreshAsync(cts.Token);
        AppLog.Note("tasks", "page shown");
        if (e.Parameter is PlaceArgs { Argument: string taskId }) OpenTask(taskId);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _poll?.Cancel();
        _selection.End();   // Select ends as the page goes
        if (_store != null) { _store.Changed -= OnChanged; _store.Notice -= OnStoreNotice; }
        if (_ideasStore != null) { _ideasStore.Changed -= OnChanged; _ideasStore.Notice -= OnIdeaNotice; }
    }

    /// Read on show and every 30 s while it shows (`?since=` answers "unchanged" when nothing moved).
    private async Task PollAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _store != null)
        {
            await _store.RefreshAsync();
            try { await Task.Delay(TimeSpan.FromSeconds(30), ct); } catch (OperationCanceledException) { return; }
        }
    }

    private void OnChanged() => _ui.TryEnqueue(() => { Render(); _taskPane?.Render(); _goalPane?.Render(); });

    // ------------------------------------------------------------------ drawing

    private IReadOnlyList<string> BotOrder => [.. PageKit.Bots.Select(b => b.Name)];

    private void Render()
    {
        if (_store is not { } store) return;
        var now = DateTimeOffset.Now;
        var sections = store.Sections;
        if (_view.ListId is { } id && !sections.Any(s => s.Id == id)) _view = TodoView.Today;
        if (_view == TodoView.Bots && !TodoViews.ShowsBots(store.Tasks)) _view = TodoView.Today;
        // [goals] No goals and nothing to update (no list yet): Today. [WIN-47] An older add-on keeps Goals, locked.
        if (GoalsAddOn.FallsBack(_view, store.GoalsSupported, store.GoalsNeedAddOn)) _view = TodoView.Today;
        RenderPills(store, now);
        RenderBar(store);
        _list.Children.Clear();
        _openIds = [];
        if (store.NeedsAddOn)
        {
            _list.Children.Add(State("", TasksCopy.UpdateAddOn, TasksCopy.UpdateAddOnText(HostWord.UpdateTarget), null, null));
            return;
        }
        if (!store.HasList)
        {
            if (!store.Loading && store.Error is { } reason)
                _list.Children.Add(State("", TasksCopy.CouldNotLoad, reason, TasksCopy.TryAgain, () => _ = store.RefreshAsync(force: true)));
            else
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 40, 0, 0) };
                row.Children.Add(new ProgressRing { IsActive = true, Width = 18, Height = 18 });
                row.Children.Add(Text(KanbanCopy.Loading, 14, color: Secondary));
                _list.Children.Add(row);
            }
            return;
        }
        var searching = _query.Trim().Length > 0;
        // [WIN-47] [goals-addon] Goals on an add-on without them: the update state alone, no task lines.
        if (GoalsAddOn.Locked(_view, searching, store.GoalsSupported))
        {
            _list.Children.Add(GoalsLockedState(store));
            return;
        }
        // [WIN-47] A search's Goals group first (the Goals view's cards, any status), then To Do and Done.
        var goalsFound = searching && RenderFoundGoals(store, now);
        // [WIN-42] The Goals view: its cards, not tasks (TasksViewController.appendGoals).
        if (_view == TodoView.Goals && !searching)
        {
            RenderGoals(store, now);
            return;
        }
        // [tasks-v2] Today Check-in strip + pending List/Goal Offers at the top of Today.
        if (_view == TodoView.Today && !searching)
        {
            RenderTodayCheckInStrip(store, now);
            RenderTodayOffers(store, now);
        }
        // [WIN-42] Today leads with the Goals shelf while there is an active goal (GoalShelf.shows).
        if (GoalShelf.Shows(_view, searching, "all", store.GoalsSupported, store.Goals)) _list.Children.Add(GoalShelfView(store, now));
        if (store.Tasks.Count == 0 && !goalsFound)
        {
            _list.Children.Add(State("", TasksCopy.NoTasks, TasksCopy.NothingText, TasksCopy.NewTask, NewTask));
            return;
        }
        var tasks = TodoSections.Filtered(store.Tasks, _query, store.Goals);
        // [WIN-53] A search looks through every view (Goals too): To Do, then Done (TasksViewController.reload).
        var groups = searching ? TodoViews.SearchGroups(tasks, Zone) : TodoViews.Groups(tasks, _view, sections, BotOrder, now, Zone, store.Settings.Sort);
        if (groups.Count == 0)
        {
            if (goalsFound) return;   // the Goals group is the search's match
            var empty = _query.Trim().Length > 0 ? $"No Results for “{_query.Trim()}”" : TodoViews.EmptyText(_view, ListName(_view.ListId));
            var t = Text(empty, 14, color: Secondary);
            t.Margin = new Thickness(4, 16, 4, 0);
            _list.Children.Add(t);
            if (_view == TodoView.Inbox && !searching) RenderInboxIdeas(store, now);
            return;
        }
        foreach (var group in groups)
        {
            // TasksViewController.configureHeader / reload at 93f984bb1: Done stays folded under its heading until Show
            // (Hide folds it again; a search shows its rows with no fold), Today calls it "Done Today", and a search's
            // open tasks are "To Do". `_doneOpen` is the page's own, as the Mac's instance var: never saved.
            if (TodoViews.PageHeading(group.Kind, _view, searching, now, Zone, sections, BotName) is { } h)
                _list.Children.Add(GroupHeading(group, h.Title, h.Detail, TodoViews.DoneFold(group.Kind, _doneOpen, searching)));
            if (!TodoViews.ShowsRows(group.Kind, _doneOpen, searching)) continue;
            var arranging = group.Kind == TodoGroupKind.Open && _view.ListId != null && _query.Trim().Length == 0;
            if (arranging) _openIds = [.. group.Tasks.Select(t => t.Id)];
            foreach (var task in group.Tasks) _list.Children.Add(RowView(task, group.Kind, now, arranging));
            if (group.Kind.IsNext && group.More > 0 && group.Kind.Arg is { } list)
            {
                var more = new HyperlinkButton { Content = TodoViews.MoreLine(group.More, ListName(list) ?? "List") + " ›" };
                more.Click += (_, _) => { _view = TodoView.List(list); Render(); };
                _list.Children.Add(more);
            }
        }
        // [tasks-v2] Inbox foot Ideas section ("Suggested by {Bot}" with Add / Add & Start / Dismiss + Undo / Look Now).
        if (_view == TodoView.Inbox && !searching) RenderInboxIdeas(store, now);
    }

    /// A group's heading (TodoGroupHeaderView): Mac calm small-caps section header ("TODAY · 6", "WAITING ON YOU · 4"),
    /// with Overdue in hqRed and Done's Show or Hide at its end. Its identifier stays "tasks.section.<title>".
    private FrameworkElement GroupHeading(TodoGroup group, string title, string? detail, string? fold)
    {
        var head = new TextBlock { FontSize = 11.5, CharacterSpacing = 45, VerticalAlignment = VerticalAlignment.Center };
        // Overdue's name in hqRed (TodoGroupHeaderView.Words: the name red, its count still grey).
        var name = new Run
        {
            Text = title.ToUpperInvariant(),
            FontWeight = FontWeights.SemiBold,
            Foreground = TodoViews.HeadingIsRed(group.Kind) ? Brush("HQRedBrush") : Secondary,
        };
        head.Inlines.Add(name);
        if (detail is { } d) head.Inlines.Add(new Run { Text = "  ·  " + d.ToUpperInvariant(), Foreground = Secondary, FontSize = 11.5 });
        if (!group.Kind.IsDay) head.Inlines.Add(new Run { Text = "  ·  " + (group.Tasks.Count + group.More), Foreground = Secondary });
        AutomationProperties.SetHeadingLevel(head, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        // TodoGroupHeaderView's padding: 18 over, 6 under; the name starts where the rows' circles do (a row's 6 in).
        var row = new Grid { Margin = new Thickness(6, 18, 8, 6) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(head);
        AutomationProperties.SetAutomationId(row, TodoViews.SectionAutomationId(title));
        if (fold != null)
        {
            var toggle = new HyperlinkButton { Content = fold, Padding = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetAutomationId(toggle, TodoViews.DoneFoldId);
            toggle.Click += (_, _) => { _doneOpen = !_doneOpen; Render(); };
            Grid.SetColumn(toggle, 1);
            row.Children.Add(toggle);
        }
        return row;
    }

    private string? ListName(string? id) => _store?.Sections.FirstOrDefault(s => s.Id == id)?.Name;

    private void RenderPills(TasksStore store, DateTimeOffset now)
    {
        _pills.Children.Clear();
        if (!store.HasList || store.NeedsAddOn) return;
        var sections = store.Sections;
        var goalsPill = GoalsAddOn.Pill(store.GoalsSupported, store.GoalsNeedAddOn, store.Goals);
        int? Count(TodoView v) => v == TodoView.Goals ? goalsPill.Count : TodoViews.OpenCount(store.Tasks, v, sections, now, Zone);
        var views = new List<(TodoView View, string Title)> { (TodoView.Today, TasksCopy.Today), (TodoView.Upcoming, TasksCopy.Upcoming), (TodoView.Inbox, TasksCopy.Inbox) };
        // [WIN-42] Goals is the first pill, with its active goals, on an add-on that keeps goals. [WIN-47] On one from
        // before Goals it stays, with no count, and says to update the add-on.
        if (goalsPill.Shows) views.Insert(0, (TodoView.Goals, GoalsCopy.Goals));
        views.AddRange(sections.Select(s => (TodoView.List(s.Id), s.Name)));
        if (TodoViews.ShowsBots(store.Tasks)) views.Add((TodoView.Bots, TasksCopy.Bots));
        foreach (var (view, title) in views)
        {
            var picked = view == _view;
            var words = new TextBlock { FontSize = 14 };
            words.Inlines.Add(new Run { Text = title, FontWeight = FontWeights.SemiBold });
            // [WIN-TASK-PILL-COUNT] The count only above 0 (TaskViewsHeader.swift line 76): an emptied Home reads "Home".
            var count = Count(view);
            var contrast = ContrastPair(Hermes.Core.Settings.ContrastTheme.PillSurface(picked));
            if (TasksCopy.PillDetail(count) is { } detail)
                words.Inlines.Add(new Run { Text = "  " + detail, Foreground = contrast?.Ink ?? (picked ? Brush("TextOnAccentFillColorSecondaryBrush") : Secondary) });
            var pill = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = words, IsChecked = picked, CornerRadius = new CornerRadius(16), Padding = new Thickness(12, 5, 12, 6) };
            if (contrast is { } pair) ContrastPill(pill, "ToggleButton", picked ? "Checked" : "", pair, words);
            AutomationProperties.SetName(pill, TasksCopy.PillName(title, count));
            AutomationProperties.SetAutomationId(pill, "tasks.view." + view.Key);
            var v = view;
            pill.Click += (_, _) => { _view = v; Render(); };
            if (view.ListId is { } listId && store.EditsLists) pill.ContextFlyout = ListMenu(store, listId);
            _pills.Children.Add(pill);
        }
        // + New List after the views (TaskViewsHeader.swift), while your lists can be edited.
        if (store.EditsLists)
        {
            var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var plus = new FontIcon { Glyph = "\uE710", FontSize = 12, Foreground = Secondary };
            var addWords = new TextBlock { Text = TodoListCopy.NewList, FontSize = 14, FontWeight = FontWeights.SemiBold };
            face.Children.Add(plus);
            face.Children.Add(addWords);
            var add = new Button { Content = face, CornerRadius = new CornerRadius(16), Padding = new Thickness(10, 5, 12, 6) };
            if (ContrastPair(Hermes.Core.Settings.ContrastTheme.Surface.Pill) is { } pair)
            {
                plus.Foreground = pair.Ink;
                ContrastPill(add, "Button", "", pair, addWords);
            }
            AutomationProperties.SetName(add, TodoListCopy.NewList);
            AutomationProperties.SetAutomationId(add, "tasks.view.new-list");
            add.Click += (_, _) => _ = PromptNewListAsync([]);
            _pills.Children.Add(add);
        }
    }

    /// [WIN-CONTRAST-BUBBLE] Under a Windows contrast theme a pill is the theme's own pair (Hermes.Core.Settings
    /// ContrastTheme): the picked one Highlight under HighlightText (the Mac's `hqTint` under `Theme.pickedPillInk`), the
    /// others ButtonFace under ButtonText (`hqFill3` under `hqLabel`), the count in the same ink. Null without a
    /// contrast theme (the look's own colours), or when Windows won't say its colours.
    internal static (SolidColorBrush Fill, SolidColorBrush Ink, SolidColorBrush Edge)? ContrastPair(Hermes.Core.Settings.ContrastTheme.Surface surface)
    {
        if (!HermesHQ.Features.Settings.ThemeService.SystemHighContrast) return null;
        var want = Hermes.Core.Settings.ContrastTheme.For(surface);
        return HermesHQ.Features.Settings.ThemeService.SystemBrush(want.Fill) is { } fill
            && HermesHQ.Features.Settings.ThemeService.SystemBrush(want.Ink) is { } ink
            && HermesHQ.Features.Settings.ThemeService.SystemBrush(want.Edge) is { } edge ? (fill, ink, edge) : null;
    }

    /// The pill's fill, words and edge in every state (rest, pointer over, pressed) from the pair, through the control's
    /// lightweight keys (`ToggleButtonBackgroundChecked`, `ButtonForegroundPointerOver`…), its words without WinUI's
    /// backplate. The fill stays put under the pointer, as the Mac's pill does.
    private static void ContrastPill(Control pill, string kind, string state, (SolidColorBrush Fill, SolidColorBrush Ink, SolidColorBrush Edge) pair, TextBlock words)
    {
        foreach (var over in new[] { "", "PointerOver", "Pressed" })
        {
            pill.Resources[$"{kind}Background{state}{over}"] = pair.Fill;
            pill.Resources[$"{kind}Foreground{state}{over}"] = pair.Ink;
            pill.Resources[$"{kind}BorderBrush{state}{over}"] = pair.Edge;
        }
        pill.Background = pair.Fill;
        pill.Foreground = pair.Ink;
        pill.BorderBrush = pair.Edge;
        words.Foreground = pair.Ink;
        HermesHQ.Features.Settings.ThemeService.ContrastWords(words);
    }

    /// A right-click on a list's pill (TaskViewsHeader.swift `menu(for:)`): Edit List… (name, colour, icon, its bot,
    /// Today), Rename…, Move Left, Move Right, then Delete List….
    private MenuFlyout ListMenu(TasksStore store, string id)
    {
        var menu = new MenuFlyout();
        var at = store.Sections.ToList().FindIndex(s => s.Id == id);
        foreach (var entry in TodoListCopy.Menu(Math.Max(at, 0), store.Sections.Count))
        {
            switch (entry)
            {
                case TodoListMenuItem.Divider: menu.Items.Add(new MenuFlyoutSeparator()); continue;
            }
            var (glyph, run) = entry switch
            {
                TodoListMenuItem.EditList => ("\uE9E9", (Action)(() => _ = EditListAsync(id))),
                TodoListMenuItem.Rename => ("\uE8AC", () => _ = RenameListAsync(id)),
                TodoListMenuItem.MoveLeft => ("\uE72B", () => _ = store.MoveSectionAsync(id, -1)),
                TodoListMenuItem.MoveRight => ("\uE72A", () => _ = store.MoveSectionAsync(id, 1)),
                _ => ("\uE74D", () => _ = DeleteListAsync(id)),
            };
            var item = Item(TodoListCopy.Title(entry), glyph, run);
            AutomationProperties.SetAutomationId(item, "tasks.list-menu." + entry.ToString().ToLowerInvariant());
            if (entry == TodoListMenuItem.DeleteList) item.Foreground = Critical;
            menu.Items.Add(item);
        }
        return menu;
    }

    // ------------------------------------------------------------------ your lists (TasksViewController.swift "Lists")

    /// Asks for a list's name (askName): the field says "List Name", Add (or Save) waits for a name, and a rename
    /// starts with the old name selected so typing replaces it. The trimmed name, or null when cancelled.
    private async Task<string?> AskNameAsync(string title, string? message, string name, string action)
    {
        var field = new TextBox { Text = name, PlaceholderText = TodoListCopy.NamePlaceholder };
        AutomationProperties.SetAutomationId(field, "tasks.list-name");
        var stack = new StackPanel { Spacing = 10, MinWidth = 300 };
        if (message != null) stack.Children.Add(Text(message, 14));
        stack.Children.Add(field);
        var dialog = new ContentDialog
        {
            Title = title, Content = stack, PrimaryButtonText = action, CloseButtonText = TodoListCopy.Cancel,
            DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = TodoListCopy.CleanName(name) != null,
        };
        field.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = TodoListCopy.CleanName(field.Text) != null;
        field.Loaded += (_, _) => { field.Focus(FocusState.Programmatic); field.SelectAll(); };
        if (await PageKit.ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary) return null;
        return TodoListCopy.CleanName(field.Text);
    }

    /// New List (the + pill, or Move To › New List… with `ids`): makes the list, moves the tasks into it, shows it.
    private async Task PromptNewListAsync(List<string> ids, Action? after = null)
    {
        if (_store is not { } store) return;
        if (store.ReadOnlyGateway) { _notice.Show(KanbanRest.ReadOnlyNotice); return; }
        if (await AskNameAsync(TodoListCopy.NewList, TodoListCopy.NewListMessage, "", TodoListCopy.Add) is not { } name) return;
        if (await store.AddSectionAsync(name) is not { } made) return;
        if (ids.Count > 0) await store.MoveAsync(ids, made.Id);
        after?.Invoke();
        _view = TodoView.List(made.Id);
        Render();
    }

    private async Task RenameListAsync(string id)
    {
        if (_store is not { } store || store.Sections.FirstOrDefault(s => s.Id == id) is not { } section) return;
        if (await AskNameAsync(TodoListCopy.RenameList, null, section.Name, TodoListCopy.Save) is not { } name) return;
        await store.RenameSectionAsync(id, name);
    }

    /// [WIN-TASK-LIST-EDIT] Edit List… (TasksViewController.swift editList): refused with the notice on a read-only
    /// gateway; Delete List… in it closes the editor, then asks (the Mac dismisses the sheet, then alerts).
    private async Task EditListAsync(string id)
    {
        if (_store is not { } store) return;
        if (TaskListEditModel.Refusal(store, id) is { } refusal) { _notice.Show(refusal); return; }
        var bots = PageKit.Bots.Select(b => (b.Name, BotName(b.Name))).ToList();
        if (TaskListEditModel.Open(store, id, bots) is not { } model) return;
        var delete = await TaskListEditDialog.PresentAsync(XamlRoot, model);
        Render();
        if (delete) await DeleteListAsync(id);
    }

    /// Delete List: “Delete “Home”?”, saying its tasks are kept in no list; Cancel, or Delete List.
    private async Task DeleteListAsync(string id)
    {
        if (_store is not { } store) return;
        await TodoListDelete.RunAsync(store, id, async (title, message) =>
        {
            var dialog = new ContentDialog
            {
                Title = title, Content = message == null ? null : Text(message, 14),
                PrimaryButtonText = TodoListCopy.DeleteList, CloseButtonText = TodoListCopy.Cancel, DefaultButton = ContentDialogButton.Close,
            };
            return await PageKit.ShowAsync(XamlRoot, dialog) == ContentDialogResult.Primary;
        });
    }

    private static Color ToneColor(TodoTone tone) => tone switch
    {
        TodoTone.NeedsYou => Rgb(0xD9, 0x77, 0x06),
        TodoTone.Overdue => Red,
        TodoTone.Ready or TodoTone.Working => Rgb(0x6E, 0x6E, 0x73),
        _ => Rgb(0x8E, 0x8E, 0x93),
    };

    private static string? CalmStatusLabel(TodoTask task, TodoRowWords words) => task.Status switch
    {
        "needs_you" => "Needs you",
        "ready" => "Ready",
        "working" => task.Helper is { } h ? $"{BotName(h)} is on it" : "Working",
        _ => null,
    };

    private static string CalmDetailText(TodoTask task, TodoRowWords words)
    {
        if (words.Note is not { Length: > 0 } note) return "";
        if (task.Helper is { } h)
        {
            var prefix = BotName(h) + ": ";
            if (note.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return note[prefix.Length..];
            var asks = BotName(h) + " asks: ";
            if (note.StartsWith(asks, StringComparison.OrdinalIgnoreCase)) return note[asks.Length..];
        }
        return note;
    }

    internal static Color? PriorityColor(int priority) => priority switch { 1 => Red, 2 => Rgb(0xEE, 0x94, 0x00), 3 => Blue, _ => null };

    /// The circle that ticks a task off (coloured by its priority).
    internal static Button Circle(TodoTask task, Func<Task> toggle)
    {
        var ring = new Ellipse { Width = 20, Height = 20, StrokeThickness = 1.5 };
        ring.Stroke = PriorityColor(task.Priority) is { } c && !task.IsDone ? Solid(c) : Tertiary;
        var grid = new Grid();
        grid.Children.Add(ring);
        if (task.IsDone)
        {
            ring.Fill = Accent;
            ring.Stroke = Accent;
            grid.Children.Add(new FontIcon { Glyph = "", FontSize = 11, Foreground = Brush("TextOnAccentFillColorPrimaryBrush") });
        }
        var button = new Button { Content = grid, Padding = new Thickness(2), Style = Style("QuietButtonStyle"), VerticalAlignment = VerticalAlignment.Top };
        AutomationProperties.SetName(button, task.IsDone ? "Done. Open it again" : TasksCopy.MarkDone);
        button.Click += (_, _) => _ = toggle();
        button.Tapped += (_, e) => e.Handled = true;   // the row under it doesn't open the task
        return button;
    }

    /// [WIN-58] A task's row as the keyboard reaches it: the Mac's rows are a collection view's cells, which its Tab and
    /// arrows land on (TasksViewController.swift `walkOrder`: "the system's focus used to start on it"), and Return opens
    /// the task. The row itself is a Border, which takes no focus, so it sits in a tab stop drawing the system's ring;
    /// Enter or Space does what a click does (opens the task, or picks it while Select picks).
    private FrameworkElement RowView(TodoTask task, TodoGroupKind kind, DateTimeOffset now, bool arranging = false)
    {
        var row = RowBody(task, kind, now, arranging);
        var host = new ContentControl
        {
            Content = row, IsTabStop = true, UseSystemFocusVisuals = true,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch,
        };
        AutomationProperties.SetAutomationId(host, Hermes.Core.Shell.KeyboardOnlyWalkProof.TaskRowPrefix + task.Id);
        // Narrator reads the stop the keyboard lands on: the row's own words (title, when, steps…), not an unnamed pane.
        AutomationProperties.SetName(host, AutomationProperties.GetName(row));
        host.KeyDown += (_, e) =>
        {
            if (e.Key is not (Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space)) return;
            e.Handled = true;
            if (_selection.Active) TogglePicked(task.Id); else OpenTask(task.Id);
        };
        return host;
    }

    private FrameworkElement RowBody(TodoTask task, TodoGroupKind kind, DateTimeOffset now, bool arranging)
    {
        var words = TodoViews.Row(task, kind, now, Zone, BotName);
        var wide = ActualWidth <= 0 || ActualWidth >= 720;
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(6, wide ? 5 : 6, 8, wide ? 5 : 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (wide)
        {
            // Mac calm wide table columns: status | detail & due | goal mark + owner with bot face.
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        }
        else
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        }
        grid.Children.Add(_selection.Active ? PickCircle(task) : Circle(task, () => ToggleDone(task)));
        var middle = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        var name = new TextBlock { FontSize = wide ? 13.5 : 15, TextWrapping = wide ? TextWrapping.NoWrap : TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis };
        if (!task.IsDone && task.Priority is 1 or 2)
        {
            var bang = task.Priority == 1 ? "!! " : "! ";
            name.Inlines.Add(new Run
            {
                Text = bang,
                FontWeight = FontWeights.SemiBold,
                Foreground = HermesHQ.Features.Settings.ThemeService.Ink(PriorityColor(task.Priority) ?? Red),
            });
        }
        name.Inlines.Add(new Run { Text = task.Title.Length == 0 ? TasksCopy.Untitled : task.Title, Foreground = task.IsDone ? Secondary : Brush("TextFillColorPrimaryBrush") });
        if (words.Steps is { } steps) name.Inlines.Add(new Run { Text = "   ☰ " + steps, FontSize = 12, Foreground = Secondary });
        if (words.Repeats) name.Inlines.Add(new Run { Text = "  ↻", FontSize = 12, Foreground = Secondary });
        foreach (var tag in words.Tags) name.Inlines.Add(new Run { Text = "  #" + tag, FontSize = 12, Foreground = Accent });
        middle.Children.Add(name);
        if (!wide && words.Note is { } noteNarrow) middle.Children.Add(Text(noteNarrow, 12, color: HermesHQ.Features.Settings.ThemeService.Ink(ToneColor(words.Tone)), wrap: false));
        Grid.SetColumn(middle, 1);
        grid.Children.Add(middle);

        // [WIN-47] A task in an active or paused goal carries the goal's mark (TaskRowViews.swift), in every view.
        var markGoal = _store is { } s0 ? GoalViews.MarkGoal(task, s0.Goals) : null;
        if (wide)
        {
            var statusLabel = CalmStatusLabel(task, words);
            var statusBlock = new TextBlock
            {
                Text = statusLabel ?? "",
                FontSize = 12.5,
                MinWidth = statusLabel != null ? 92 : 0,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = HermesHQ.Features.Settings.ThemeService.Ink(ToneColor(words.Tone)),
            };
            Grid.SetColumn(statusBlock, 2);
            grid.Children.Add(statusBlock);

            var detailPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
            var detailText = CalmDetailText(task, words);
            if (detailText.Length > 0) detailPanel.Children.Add(Text(detailText, 12.5, color: Secondary, wrap: false));
            if (words.When is { } when) detailPanel.Children.Add(Text(when, 12.5, color: words.Late ? Critical : Secondary, wrap: false));
            if (markGoal != null) detailPanel.Children.Add(GoalMarkView(markGoal, task.IsDone));
            Grid.SetColumn(detailPanel, 3);
            grid.Children.Add(detailPanel);

            var who = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center, MinWidth = 104 };
            if (task.Helper is { } helper)
            {
                who.Children.Add(Face(helper, 18));
                var ownerLabel = task.WhoKind == TodoWho.Bot ? BotName(helper) : "You & " + BotName(helper);
                who.Children.Add(Text(ownerLabel, 12.5, color: Secondary, wrap: false));
            }
            else
            {
                who.Children.Add(Text("You", 12.5, color: Secondary, wrap: false));
            }
            Grid.SetColumn(who, 4);
            grid.Children.Add(who);
        }
        else
        {
            var end = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
            if (words.When is { } when) end.Children.Add(Text(when, 12, color: words.Late ? Critical : Secondary, wrap: false));
            if (markGoal != null) end.Children.Add(GoalMarkView(markGoal, task.IsDone));
            if (task.Helper is { } helper)
            {
                var face = new Grid { Width = 22, Height = 22 };
                face.Children.Add(Face(helper, 22));
                if (words.Dot is { } dot)
                {
                    face.Children.Add(new Ellipse
                    {
                        Width = 8, Height = 8, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
                        Fill = Solid(dot == "ready" ? Green : dot == "question" ? Red : Blue), Stroke = Brush("LayerFillColorDefaultBrush"), StrokeThickness = 1,
                    });
                }
                end.Children.Add(face);
            }
            Grid.SetColumn(end, 2);
            grid.Children.Add(end);
        }
        var chosen = _selected == task.Id;
        var row = new Border { Child = grid, CornerRadius = new CornerRadius(6), Background = chosen ? AccentWash(0.14) : Solid(Microsoft.UI.Colors.Transparent) };
        AutomationProperties.SetName(row, $"{task.Title}. {string.Join(", ", new[] { words.When, words.Steps is { } s ? s.Replace("/", " of ") + " steps" : null, words.Note, markGoal is { } mg ? GoalViews.MarkWords(mg) : null }.OfType<string>())}");
        AutomationProperties.SetAutomationId(row, "tasks.row." + task.Id);
        row.PointerEntered += (_, _) => { if (_selected != task.Id) row.Background = Brush("SubtleFillColorSecondaryBrush"); };
        row.PointerExited += (_, _) => { if (_selected != task.Id) row.Background = Solid(Microsoft.UI.Colors.Transparent); };
        if (_selection.Active)
        {
            // Select: a click picks the row (nothing opens, no menu, no drag). A picked row shows the filled check only,
            // with no tint (the Mac's cell isn't selected).
            var picked = _selection.IsPicked(task.Id);
            AutomationProperties.SetItemStatus(row, picked ? "Selected" : "");
            row.Tapped += (_, _) => TogglePicked(task.Id);
            return row;
        }
        row.Tapped += (_, _) => OpenTask(task.Id);
        row.ContextFlyout = RowMenu(task);
        if (arranging) AllowArrange(row, task);
        return row;
    }

    private MenuFlyout RowMenu(TodoTask task)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(Item(TasksCopy.OpenTask, "", () => OpenTask(task.Id)));
        menu.Items.Add(Item(task.IsDone ? TasksCopy.MarkNotDone : TasksCopy.MarkDone, task.IsDone ? "" : "", () => _ = ToggleDone(task)));
        if (_store is { } store && (store.Sections.Count > 0 || store.EditsLists))
        {
            var move = new MenuFlyoutSubItem { Text = TasksCopy.MoveTo, Icon = new FontIcon { Glyph = "" } };
            AddMoveChoices(move.Items, store, [task.Id], null);
            menu.Items.Add(move);
        }
        // [WIN-47] Add to Goal, beside Move To (docs/goals.md "A task in a goal").
        if (_store is { } goalStore && AddToGoalMenu(goalStore, task) is { } goalMenu) menu.Items.Add(goalMenu);
        var select = Item(TodoSelection.RowMenuTitle, "\uE73A", () => { _selection.StartWith(task.Id); Render(); });
        AutomationProperties.SetAutomationId(select, "tasks.select.row");
        menu.Items.Add(select);
        menu.Items.Add(new MenuFlyoutSeparator());
        var delete = Item(TasksCopy.Delete, "", () => _ = ConfirmDeleteAsync(task.Id));
        delete.Foreground = Critical;
        menu.Items.Add(delete);
        return menu;
    }

    // ------------------------------------------------------------------ Sort By, Select, drag

    /// ⋯: Sort By (a list's view only) with My Order, Due Date, Priority (0.9.53), Date Added; then Select Tasks; then
    /// Tasks Settings….
    private void FillMoreMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        if (_store is not { } store) return;
        if (TodoSortBy.Shows(_view))
        {
            var sort = store.Settings.Sort;
            var sub = new MenuFlyoutSubItem { Text = TodoSortBy.Title, Icon = new FontIcon { Glyph = "\uE8CB" } };
            // The Mac's submenu says the sort in force under its title; here it is the item's help text and tip.
            if (TodoSortBy.Subtitle(sort) is { } subtitle)
            {
                AutomationProperties.SetHelpText(sub, subtitle);
                ToolTipService.SetToolTip(sub, subtitle);
            }
            AutomationProperties.SetAutomationId(sub, "tasks.sort.menu");
            foreach (var option in TodoSortBy.Options(store.FieldsSupported, sort))
            {
                var key = option.Key;
                var item = new RadioMenuFlyoutItem { Text = option.Title, GroupName = "tasks-sort", IsChecked = sort == key, Icon = new FontIcon { Glyph = option.Glyph } };
                AutomationProperties.SetAutomationId(item, "tasks.sort." + key);
                item.Click += (_, _) => _ = store.SetSortAsync(key);
                sub.Items.Add(item);
            }
            menu.Items.Add(sub);
        }
        var select = Item(TodoSelection.MenuTitle, "\uE73A", () => SetSelecting(true));
        AutomationProperties.SetAutomationId(select, "tasks.select.start");
        menu.Items.Add(select);
        // Tasks Settings… last (the Mac's Import from Reminders… sits between; Windows has no Reminders).
        menu.Items.Add(new MenuFlyoutSeparator());
        var settings = Item(TodoSettingsCopy.MenuTitle, "\uE713", () => _ = TasksSettingsDialog.PresentAsync(XamlRoot, store));
        AutomationProperties.SetAutomationId(settings, "tasks.settings.open");
        menu.Items.Add(settings);
    }

    /// The bar: the page's buttons, or Select's (its three greyed with nothing picked or on a read-only gateway).
    private void RenderBar(TasksStore store)
    {
        var on = _selection.Active;
        _tools.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        _selectBar.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        _tools.IsHitTestVisible = !store.NeedsAddOn;
        _tools.Opacity = store.NeedsAddOn ? 0.4 : 1;
        // [WIN-47] The bar's + in Goals makes a goal ("New Goal"; "Update Add-on" on an older add-on), line 805.
        var addLabel = GoalsAddOn.AddLabel(_view, store.GoalsNeedAddOn);
        AutomationProperties.SetName(_add, addLabel);
        ToolTipService.SetToolTip(_add, addLabel);
        if (!on) return;
        var can = _selection.CanAct(SelectedIds().Count, store.ReadOnlyGateway);
        _selectMove.IsEnabled = _selectDone.IsEnabled = _selectDelete.IsEnabled = can;
    }

    private List<string> SelectedIds() => _store is { } store ? _selection.SelectedIds(id => store.Find(id) != null) : [];

    private void SetSelecting(bool on)
    {
        if (on == _selection.Active) return;
        if (on) _selection.Start(); else _selection.End();
        Render();
    }

    private void TogglePicked(string id)
    {
        _selection.Toggle(id);
        Render();
    }

    /// The pick circle that stands in for the tick circle while selecting (filled when picked).
    private FrameworkElement PickCircle(TodoTask task)
    {
        var picked = _selection.IsPicked(task.Id);
        var ring = new Ellipse { Width = 20, Height = 20, StrokeThickness = 1.5, Stroke = picked ? Accent : Tertiary, Fill = picked ? Accent : null };
        var grid = new Grid { Margin = new Thickness(2), VerticalAlignment = VerticalAlignment.Top };
        grid.Children.Add(ring);
        if (picked) grid.Children.Add(new FontIcon { Glyph = "\uE73E", FontSize = 11, Foreground = Brush("TextOnAccentFillColorPrimaryBrush") });
        AutomationProperties.SetAutomationId(grid, "tasks.select.pick." + task.Id);
        AutomationProperties.SetAccessibilityView(grid, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return grid;
    }

    /// Move To's places: No List, then each list, the one every task is in ticked.
    private void AddMoveChoices(IList<MenuFlyoutItemBase> items, TasksStore store, List<string> ids, Action? after)
    {
        var tick = TodoSelection.MoveTick(ids, store.Find);
        foreach (var (id, name) in new[] { ("", TasksCopy.NoList) }.Concat(store.Sections.Select(s => (s.Id, s.Name))))
        {
            var place = id;
            var item = new ToggleMenuFlyoutItem { Text = name, IsChecked = tick == place };
            AutomationProperties.SetAutomationId(item, "tasks.move." + (place.Length == 0 ? "none" : place));
            item.Click += async (_, _) =>
            {
                await store.MoveAsync(ids, place.Length == 0 ? null : place);
                after?.Invoke();
            };
            items.Add(item);
        }
        // New List…: names a list, moves these tasks into it and shows it (moveChoices' last item).
        items.Add(new MenuFlyoutSeparator());
        var make = Item(TodoListCopy.NewListEllipsis, "\uE710", () => _ = PromptNewListAsync(ids, after));
        AutomationProperties.SetAutomationId(make, "tasks.move.new-list");
        items.Add(make);
    }

    private void FillSelectMove(MenuFlyout menu)
    {
        menu.Items.Clear();
        if (_store is not { } store || SelectedIds() is not { Count: > 0 } ids) return;
        AddMoveChoices(menu.Items, store, ids, () => SetSelecting(false));
    }

    private void MarkSelectedDone()
    {
        if (_store is not { } store || SelectedIds() is not { Count: > 0 } ids) return;
        SetSelecting(false);
        _ = Task.WhenAll(TodoSelection.ToMarkDone(ids, store.Find).Select(id => store.SetDoneAsync(id, true)));
    }

    private async Task DeleteSelectedAsync()
    {
        if (_store is not { } store || SelectedIds() is not { Count: > 0 } ids) return;
        var dialog = new ContentDialog
        {
            Title = TodoSelection.DeleteTitle(ids.Count), PrimaryButtonText = TasksCopy.Delete, CloseButtonText = TasksCopy.Cancel,
            DefaultButton = ContentDialogButton.Close,
        };
        if (await PageKit.ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary) return;
        SetSelecting(false);
        if (_selected is { } open && ids.Contains(open)) CloseTask();
        foreach (var id in ids) await store.DeleteAsync(id);
    }

    /// A list's open row can be dragged up or down it; the drop sets its position halfway between its new neighbours
    /// (in another sort too, which then says why the row went back to its sorted place). TasksViewController.swift at
    /// 93f984bb1, "MARK: Drag a task up or down its list": the rules are Hermes.Core's `TodoArrange` / `TodoDropPlace`.
    /// The Mac ticks (a selection haptic) each time the held task reaches a new place; a Windows pointer has no haptic,
    /// so the place shows as an accent line over or under the row it would land beside (UIKit opens a gap there).
    /// The Mac has no keyboard equivalent for this drag (no key command in the Tasks page), so neither does Windows.
    private void AllowArrange(Border row, TodoTask task)
    {
        if (_store is not { } store || !TodoArrange.CanLift(task, _view, _query.Trim().Length > 0, _selection.Active, store.ReadOnlyGateway)) return;
        row.CanDrag = true;
        row.AllowDrop = true;
        // The line drawn over (or under) this row while a held task would land there; it takes no room and no pointer.
        var mark = new Rectangle
        {
            Height = 2, Fill = Accent, IsHitTestVisible = false, Visibility = Visibility.Collapsed,
            Margin = new Thickness(-6, -6, -8, -6), RadiusX = 1, RadiusY = 1,
        };
        if (row.Child is Grid grid)
        {
            Grid.SetColumnSpan(mark, Math.Max(1, grid.ColumnDefinitions.Count));
            grid.Children.Add(mark);
        }
        void EndDrag()
        {
            _dragging = null;
            _dropPlace.Reset();   // dropSessionDidEnd
            ClearDropMark();
        }
        row.DragStarting += (_, e) =>
        {
            _dragging = task.Id;
            _dropPlace.Reset();
            e.Data.SetText(task.Title);
            e.Data.RequestedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Move;
        };
        row.DropCompleted += (_, _) => EndDrag();
        row.DragOver += (_, e) =>
        {
            // Only a task picked up here (`canHandle`: the local session's id), over an open row of this list.
            if (_dragging == null) return;
            var y = e.GetPosition(row).Y;
            if (TodoArrange.DropIndex(_openIds, task.Id, y, row.ActualHeight) is not { } at) return;
            _ = _dropPlace.Update(at);   // a new place: the Mac's tick; here the line moves
            ShowDropMark(mark, under: at > _openIds.IndexOf(task.Id));
            e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Move;
            e.Handled = true;
        };
        row.DragLeave += (_, _) =>
        {
            // dropSessionDidExit: off this row, the place is forgotten (the next row it reaches sets it again).
            if (_dropMark == mark) ClearDropMark();
        };
        row.Drop += (_, e) =>
        {
            if (_dragging is not { } id) return;
            e.Handled = true;
            var target = TodoArrange.DropIndex(_openIds, task.Id, e.GetPosition(row).Y, row.ActualHeight);
            var plan = TodoArrange.Plan(_openIds, id, target, _view, store.Find, DateTimeOffset.Now, store.Settings.Sort);
            EndDrag();
            if (plan == null) return;
            if (plan.Notice is { } why) _notice.Show(why, TodoArrange.NoticeSeconds);
            _ = store.MoveAsync([plan.Id], plan.List, plan.Position);   // a refusal's notice says why
        };
    }

    private void ShowDropMark(Rectangle mark, bool under)
    {
        if (_dropMark != null && _dropMark != mark) _dropMark.Visibility = Visibility.Collapsed;
        mark.VerticalAlignment = under ? VerticalAlignment.Bottom : VerticalAlignment.Top;
        mark.Visibility = Visibility.Visible;
        _dropMark = mark;
    }

    private void ClearDropMark()
    {
        if (_dropMark != null) _dropMark.Visibility = Visibility.Collapsed;
        _dropMark = null;
    }

    private static MenuFlyoutItem Item(string text, string glyph, Action run)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
        item.Click += (_, _) => run();
        return item;
    }

    private UIElement State(string glyph, string title, string text, string? action, Action? run)
    {
        var stack = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(24, 60, 24, 40), MaxWidth = 440 };
        stack.Children.Add(new FontIcon { Glyph = glyph, FontSize = 34, Foreground = Tertiary, Margin = new Thickness(0, 0, 0, 4) });
        var t = Text(title, 18, bold: true);
        t.TextAlignment = TextAlignment.Center;
        stack.Children.Add(t);
        var h = Text(text, 13, color: Secondary);
        h.TextAlignment = TextAlignment.Center;
        stack.Children.Add(h);
        if (action != null && run != null)
        {
            var b = Push(action, run);
            b.HorizontalAlignment = HorizontalAlignment.Center;
            b.Margin = new Thickness(0, 8, 0, 0);
            stack.Children.Add(b);
        }
        return stack;
    }

    // ------------------------------------------------------------------ actions

    internal async Task ToggleDone(TodoTask task)
    {
        if (_store == null) return;
        var nextDone = !task.IsDone;
        var ok = await _store.SetDoneAsync(task.Id, nextDone);
        if (ok && TodayCheckIn.ShouldOfferUndo(task, nextDone))
        {
            var id = task.Id;
            _notice.Show(TodayCheckIn.UndoBannerText(task), seconds: 6, action: "Undo", onAction: () => _ = _store?.SetDoneAsync(id, false));
        }
    }

    private void RenderTodayCheckInStrip(TasksStore store, DateTimeOffset now)
    {
        var summary = TodayCheckIn.Compute(store.Tasks, store.Offers, now, Zone);
        if (!summary.HasActionItems && summary.DoneToday == 0) return;
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var info = new TextBlock { FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        info.Inlines.Add(new Run { Text = "Today Check-in  ·  ", FontWeight = FontWeights.SemiBold, Foreground = Secondary });
        info.Inlines.Add(new Run { Text = summary.Headline });
        grid.Children.Add(info);
        if (summary.HasActionItems)
        {
            var btn = Quiet("Review Today", () => _ = OpenTodayCheckInDialogAsync(store, now));
            btn.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(btn, 1);
            grid.Children.Add(btn);
        }
        var card = Card(grid, 8);
        card.Margin = new Thickness(0, 4, 0, 4);
        AutomationProperties.SetAutomationId(card, "tasks.today.checkin");
        _list.Children.Add(card);
    }

    private async Task OpenTodayCheckInDialogAsync(TasksStore store, DateTimeOffset now)
    {
        var today = TodoDates.LocalDay(now, Zone);
        var overdue = store.Tasks.Where(t => !t.IsDone && TodoViews.InYourDay(t) && TodoDates.Due(t.Due, Zone) is { } d && TodoDates.LocalDay(d.Date, Zone) < today).ToList();
        var closeOffers = store.Tasks.Where(t => !t.IsDone && t.Offer is { Kept: false }).ToList();
        var panel = new StackPanel { Spacing = 10, MinWidth = 420 };

        if (overdue.Count > 0)
        {
            panel.Children.Add(Header($"Overdue ({overdue.Count})"));
            foreach (var t in overdue.Take(8))
            {
                var task = t;
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(Text(task.Title, 13, wrap: false));
                var btns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
                Border? itemCard = null;
                void DismissRow(Func<Task> work)
                {
                    if (itemCard != null) itemCard.IsHitTestVisible = false;
                    if (itemCard != null) itemCard.Opacity = 0.45;
                    _ = RunAndRemoveAsync();
                    async Task RunAndRemoveAsync()
                    {
                        try { await work(); }
                        catch (Exception ex) { AppLog.Error("tasks", ex); }
                        if (itemCard != null) panel.Children.Remove(itemCard);
                    }
                }
                btns.Children.Add(Quiet("Today", () => DismissRow(() => store.PatchAsync(task.Id, new JsonObject { ["due"] = TodoDates.Wire(now, false, Zone) }))));
                btns.Children.Add(Quiet("Tomorrow", () => DismissRow(() => store.PatchAsync(task.Id, new JsonObject { ["due"] = TodoDates.Wire(now.AddDays(1), false, Zone) }))));
                btns.Children.Add(Quiet("Done", () => DismissRow(() => ToggleDone(task))));
                Grid.SetColumn(btns, 1);
                row.Children.Add(btns);
                itemCard = Card(row, 8);
                panel.Children.Add(itemCard);
            }
        }

        if (closeOffers.Count > 0)
        {
            panel.Children.Add(Header($"Looks Done ({closeOffers.Count})"));
            foreach (var t in closeOffers.Take(6))
            {
                var task = t;
                var stack = new StackPanel { Spacing = 4 };
                stack.Children.Add(Text(task.Title, 13, bold: true));
                if (!string.IsNullOrWhiteSpace(task.Offer?.Text)) stack.Children.Add(Text(task.Offer!.Text, 12, color: Secondary));
                var btns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                Border? offerCard = null;
                void DismissOffer(Func<Task> work)
                {
                    if (offerCard != null) { offerCard.IsHitTestVisible = false; offerCard.Opacity = 0.45; }
                    _ = RunAndRemoveAsync();
                    async Task RunAndRemoveAsync()
                    {
                        try { await work(); }
                        catch (Exception ex) { AppLog.Error("tasks", ex); }
                        if (offerCard != null) panel.Children.Remove(offerCard);
                    }
                }
                btns.Children.Add(Push("Mark Done", () => DismissOffer(() => ToggleDone(task)), accent: true));
                btns.Children.Add(Quiet("Keep Open", () => DismissOffer(() => store.KeepTaskOpenAsync(task.Id))));
                stack.Children.Add(btns);
                offerCard = Card(stack, 8);
                panel.Children.Add(offerCard);
            }
        }

        if (panel.Children.Count == 0)
            panel.Children.Add(Text("Everything for today is up to date.", 14, color: Secondary));

        var dialog = new ContentDialog
        {
            Title = "Today Check-in",
            Content = new ScrollViewer { Content = panel, MaxHeight = 520 },
            CloseButtonText = TasksCopy.Done,
            DefaultButton = ContentDialogButton.Close,
        };
        await ShowAsync(XamlRoot, dialog);
        Render();
    }

    private void RenderTodayOffers(TasksStore store, DateTimeOffset now)
    {
        var waiting = TodoOfferRules.Waiting(store.Offers);
        if (waiting.Count == 0) return;
        // Show all list/task offers, and one goal offer at a time to keep Today calm.
        var shownGoal = false;
        foreach (var offer in waiting)
        {
            if (offer.IsGoalOffer)
            {
                if (shownGoal) continue;
                shownGoal = true;
            }
            var o = offer;
            var stack = new StackPanel { Spacing = 6 };
            stack.Children.Add(Text(TodoOfferRules.OfferTitle(o, BotName), 14, bold: true));
            if (!string.IsNullOrWhiteSpace(o.Summary)) stack.Children.Add(Text(o.Summary, 13, color: Secondary));
            if (o.Plan is { } plan)
            {
                foreach (var row in GoalOffers.SetupRows(plan, now, Zone))
                    stack.Children.Add(Text($"{row.Label}: {row.Value}", 12));
                if (plan.Milestones.Count > 0)
                    stack.Children.Add(Text($"{plan.Milestones.Count} milestones · {plan.Tasks.Count} tasks", 12, color: Secondary));
            }
            else if (o.AllTasks.Count > 0)
            {
                foreach (var t in o.AllTasks.Take(4))
                {
                    var itemGrid = new Grid { ColumnSpacing = 8 };
                    itemGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    itemGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    itemGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    itemGrid.Children.Add(new Ellipse { Width = 14, Height = 14, StrokeThickness = 1.25, Stroke = Tertiary, VerticalAlignment = VerticalAlignment.Center });
                    var itemTitle = Text(t.Title, 13, wrap: false);
                    Grid.SetColumn(itemTitle, 1);
                    itemGrid.Children.Add(itemTitle);
                    if (t.Due is { Length: > 0 } due && TodoDates.Due(due, Zone) is { } parsed)
                    {
                        var dueText = Text(parsed.Date.ToString("MMM d"), 12, color: Secondary, wrap: false);
                        Grid.SetColumn(dueText, 2);
                        itemGrid.Children.Add(dueText);
                    }
                    stack.Children.Add(itemGrid);
                }
            }
            var btns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 4, 0, 0) };
            foreach (var button in TodoOfferRules.OfferButtons(o))
            {
                var b = button;
                var uiBtn = Push(b.Label, () => _ = HandleOfferAsync(store, o, b.Action), accent: b.Primary);
                if (b.Destructive && !b.Primary) uiBtn.Foreground = Secondary;
                btns.Children.Add(uiBtn);
            }
            stack.Children.Add(btns);
            var card = Card(stack, 14);
            card.Margin = new Thickness(0, 4, 0, 6);
            card.BorderBrush = Brush("CardStrokeColorDefaultBrush");
            AutomationProperties.SetAutomationId(card, "tasks.offer." + o.Id);
            _list.Children.Add(card);
        }
    }

    private async Task HandleOfferAsync(TasksStore store, TodoOffer offer, TodoOfferAction action)
    {
        var answer = await store.AnswerOfferAsync(offer.Id, action);
        if (answer == null) return;
        if (action is TodoOfferAction.Accept or TodoOfferAction.AcceptNoList)
        {
            _notice.Show("Offer accepted.", seconds: 6, action: "Undo", onAction: () => _ = store.AnswerOfferAsync(offer.Id, TodoOfferAction.Undo));
        }
        else if (action == TodoOfferAction.Decline)
        {
            _notice.Show("Offer dismissed.", seconds: 6, action: "Undo", onAction: () => _ = store.AnswerOfferAsync(offer.Id, TodoOfferAction.Undo));
        }
    }

    private void RenderInboxIdeas(TasksStore store, DateTimeOffset now)
    {
        if (_ideasStore is not { } ideasStore) return;
        var page = ideasStore.Page;
        var visible = ideasStore.VisibleIdeas;

        // Show Ideas section when enabled, has ideas, or supported by settings.
        if (!page.On && visible.Count == 0 && store.Settings.Ideas == null) return;

        var head = new Grid { Margin = new Thickness(6, 20, 8, 6) };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = Text($"Suggested by {BotName(page.Bot)}", 15, bold: true);
        head.Children.Add(title);

        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (page.On)
        {
            var lookBtn = Quiet(ideasStore.Looking || page.Running ? "Looking…" : "Look Now", () => _ = ideasStore.LookNowAsync());
            lookBtn.IsEnabled = !ideasStore.Looking && !page.Running;
            tools.Children.Add(lookBtn);
        }
        else
        {
            tools.Children.Add(Push("Turn On Ideas", () => _ = ideasStore.SetOnAsync(true, store), accent: true));
        }
        Grid.SetColumn(tools, 1);
        head.Children.Add(tools);
        _list.Children.Add(head);

        if (!page.On)
        {
            _list.Children.Add(Text(TodoSettingsCopy.IdeasFooter(BotName(page.Bot)), 12, color: Secondary));
            return;
        }
        if (visible.Count == 0)
        {
            _list.Children.Add(Text(ideasStore.Looking ? "Looking through recent activity…" : "No new ideas right now.", 13, color: Secondary));
            return;
        }

        foreach (var idea in visible)
        {
            var item = idea;
            var expanded = _expandedIdeas.Contains(item.Id);
            var stack = new StackPanel { Spacing = 6 };

            var top = new Grid { ColumnSpacing = 8 };
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            top.Children.Add(Text(item.Title, 14, bold: true));
            var toggle = Quiet(expanded ? "Less" : "Details", () =>
            {
                if (!_expandedIdeas.Add(item.Id)) _expandedIdeas.Remove(item.Id);
                Render();
            });
            Grid.SetColumn(toggle, 1);
            top.Children.Add(toggle);
            stack.Children.Add(top);

            if (!string.IsNullOrWhiteSpace(item.Why))
                stack.Children.Add(Text(item.Why, 12, color: Secondary));

            if (expanded && item.From?.Line(now, Zone) is { Length: > 0 } fromLine)
                stack.Children.Add(Text("From " + fromLine, 11, color: Tertiary));

            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            actions.Children.Add(Push("Add", () => _ = ideasStore.AddAsync(item, letBotStart: false, store), accent: true));
            actions.Children.Add(Push($"Add & Let {BotName(item.Bot ?? page.Bot)} Start", () => _ = ideasStore.AddAsync(item, letBotStart: true, store)));
            var dismiss = Quiet("Dismiss", () => _ = DismissIdeaWithUndoAsync(ideasStore, item));
            actions.Children.Add(dismiss);
            stack.Children.Add(actions);

            var card = Card(stack, 10);
            card.Margin = new Thickness(0, 3, 0, 3);
            AutomationProperties.SetAutomationId(card, "tasks.idea." + item.Id);
            _list.Children.Add(card);
        }
    }

    private async Task DismissIdeaWithUndoAsync(TaskIdeasStore ideasStore, TaskIdea item)
    {
        if (await ideasStore.DismissAsync(item))
            _notice.Show($"Dismissed “{item.Title}”", seconds: 6, action: "Undo", onAction: () => _ = ideasStore.RestoreAsync(item));
    }

    internal void OpenGoal(string goalId)
    {
        if (_store == null) return;
        _selected = null;
        _taskPane = null;
        _selectedGoal = goalId;
        _goalPane = new GoalDetailPane(_store, goalId, this);
        _paneHost.Content = _goalPane;
        _pane.Visibility = Visibility.Visible;
        Render();
    }

    internal async Task ConfirmDeleteAsync(string id)
    {
        if (_store is not { } store) return;
        if (store.ReadOnlyGateway) { _notice.Show(KanbanRest.ReadOnlyNotice); return; }
        if (store.Find(id) is not { } task) return;
        var title = task.Title.Length == 0 ? TasksCopy.Untitled : task.Title;
        if (!await ConfirmAsync(XamlRoot, TasksCopy.DeleteTitle(title), TasksCopy.DeleteMessage, TasksCopy.DeleteTask)) return;
        if (_selected == id) CloseTask();
        await store.DeleteAsync(id);
    }

    internal void OpenTask(string id)
    {
        if (_store == null) return;
        _selectedGoal = null;
        _goalPane = null;
        _selected = id;
        _taskPane = new TaskPane(_store, id, this);
        _paneHost.Content = _taskPane;
        _pane.Visibility = Visibility.Visible;
        Render();
    }

    internal void CloseTask()
    {
        _taskPane = null;
        _goalPane = null;
        _selectedGoal = null;
        _paneHost.Content = null;
        _pane.Visibility = Visibility.Collapsed;
        _selected = null;
        Render();
    }

    private void NewTask()
    {
        if (_store is not { } store) return;
        if (store.ReadOnlyGateway) { _notice.Show(KanbanRest.ReadOnlyNotice); return; }
        // [WIN-42] the bar's + makes a goal in Goals; [WIN-47] on an older add-on it asks for the update.
        switch (GoalsAddOn.AddAction(_view, _query.Trim().Length > 0, store.GoalsSupported, store.GoalsNeedAddOn))
        {
            case GoalsAddAction.NewGoal: NewGoal(); return;
            case GoalsAddAction.UpdateAddOn: _ = UpdateGoalsAddOnAsync(store); return;
        }
        // The list on show is the one it starts in; Today's + starts it today.
        _ = NewTodoDialog.PresentAsync(XamlRoot, store, _view.ListId, _view == TodoView.Today ? DateTimeOffset.Now : null, made =>
        {
            if (made?.Helper is { } helper && PageKit.Bots.FirstOrDefault(b => b.Name == helper) is { } bot) Navigator.Go(new BotChatDestination(bot));
        });
    }
}
