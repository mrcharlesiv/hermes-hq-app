using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using HermesHQ.Features.QuickActions;
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
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// Tasks (`App/Pages/Tasks/TasksViewController.swift`; `docs/tasks.md`): shared hub store with foreground-gated polling
/// & live `tasks.changed`, collapsible `TasksSidebarView` (with compact view switcher/pills when collapsed or narrow),
/// dedicated `Suggested` view with Sources banner, Priority/Tag filter menus + active chips bar, Overdue `Reschedule`,
/// Select `Schedule`/`Priority`, row triage submenus + `Duplicate`, multi-week `TodoWeekStripView` in Upcoming,
/// Completed Logbook, and Favorites pinning.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class TasksPage : Page, IKeyRefreshing
{
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    private TasksStore? _store;
    private TaskIdeasStore? _ideasStore;
    private readonly HashSet<string> _expandedIdeas = [];
    private TodoView _view = TodoView.Today;

    /// View › Refresh (Ctrl+R, F5).
    public void KeyRefresh()
    {
        _ = _store?.RefreshAsync(force: true);
        if (_view == TodoView.Suggested) _ = _ideasStore?.RefreshAsync(force: true);
    }

    private string _query = "";
    private int? _priorityFilter;
    private string? _tagFilter;
    private int _upcomingWeekOffset;
    private string? _upcomingPickedDay;
    private bool _sidebarCollapsed;
    private string? _selected;
    private bool _doneOpen;

    private readonly TasksSidebarView _sidebar = new();
    private readonly Button _sidebarToggle;
    private readonly DropDownButton _compactViewPicker = new() { Visibility = Visibility.Collapsed };
    private readonly TextBlock _barTitle = new() { Text = TasksCopy.Title, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _pills = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly ScrollViewer _pillsHost;
    private readonly StackPanel _activeFiltersBar = new() { Orientation = Orientation.Horizontal, Spacing = 6, Padding = new Thickness(16, 4, 16, 4), Visibility = Visibility.Collapsed };
    private readonly TodoWeekStripView _weekStrip = new();
    private readonly StackPanel _list = new() { Spacing = 2, Padding = new Thickness(16, 4, 16, 24) };
    private readonly TextBox _search = new() { PlaceholderText = TasksCopy.SearchPlaceholder, Width = 220, VerticalAlignment = VerticalAlignment.Center };
    private readonly ContentControl _paneHost = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly Border _pane;
    private readonly NoticeLine _notice = new();
    private TaskPane? _taskPane;
    private GoalDetailPane? _goalPane;
    private string? _selectedGoal;

    private readonly Button _add = new() { Content = new FontIcon { Glyph = "\uE710", FontSize = Hermes.Core.Shell.DesktopLook.BarGlyph }, Style = Style("QuietButtonStyle") };
    private readonly TodoSelection _selection = new();
    private readonly StackPanel _tools = new() { Orientation = Orientation.Horizontal, Spacing = 4 };
    private readonly StackPanel _selectBar = new() { Orientation = Orientation.Horizontal, Spacing = 4, Visibility = Visibility.Collapsed };
    private readonly DropDownButton _selectSchedule = new() { Content = TasksCopy.Schedule };
    private readonly DropDownButton _selectPriority = new() { Content = TasksCopy.Priority };
    private readonly DropDownButton _selectMove = new() { Content = TasksCopy.MoveTo };
    private readonly Button _selectDone = new() { Content = TasksCopy.MarkDone };
    private readonly Button _selectDelete = new() { Content = TasksCopy.Delete };

    private List<string> _openIds = [];
    private string? _dragging;
    private readonly TodoDropPlace _dropPlace = new();
    private Rectangle? _dropMark;
    private static readonly TimeZoneInfo Zone = TimeZoneInfo.Local;

    public TasksPage()
    {
        AutomationProperties.SetName(this, TasksCopy.Title);
        HermesHQ.Shell.PageBar.Title(_barTitle, "tasks");

        _sidebarToggle = new Button
        {
            Content = new FontIcon { Glyph = "\uE700", FontSize = Hermes.Core.Shell.DesktopLook.BarGlyph },
            Style = Style("QuietButtonStyle"),
        };
        AutomationProperties.SetName(_sidebarToggle, "Toggle Tasks Sidebar");
        AutomationProperties.SetAutomationId(_sidebarToggle, "tasks.sidebar.toggle");
        ToolTipService.SetToolTip(_sidebarToggle, "Toggle Sidebar");
        _sidebarToggle.Click += (_, _) => { _sidebarCollapsed = !_sidebarCollapsed; Render(); };

        AutomationProperties.SetName(_compactViewPicker, "Switch Tasks View");
        AutomationProperties.SetAutomationId(_compactViewPicker, "tasks.view.switcher");
        var compactMenu = new MenuFlyout();
        compactMenu.Opening += (_, _) => FillCompactViewMenu(compactMenu);
        _compactViewPicker.Flyout = compactMenu;

        var titleLead = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        titleLead.Children.Add(_sidebarToggle);
        titleLead.Children.Add(_barTitle);
        titleLead.Children.Add(_compactViewPicker);

        var add = _add;
        AutomationProperties.SetName(add, TasksCopy.NewTask);
        AutomationProperties.SetAutomationId(add, "tasks.new");
        ToolTipService.SetToolTip(add, TasksCopy.NewTask);
        add.Click += (_, _) => NewTask();

        _search.TextChanged += (_, _) => { _query = _search.Text; Render(); };
        AutomationProperties.SetName(_search, TasksCopy.SearchPlaceholder);
        AutomationProperties.SetAutomationId(_search, "tasks.search");

        var bar = new Grid { Padding = HermesHQ.Shell.PageBar.Padding(12, 4), ColumnSpacing = 10 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(titleLead);

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

        // Select bar: Schedule, Priority, Move To, Mark Done, Delete, Done.
        AutomationProperties.SetAutomationId(_selectSchedule, "tasks.select.schedule");
        _selectSchedule.Flyout = new MenuFlyout();
        ((MenuFlyout)_selectSchedule.Flyout).Opening += (_, _) => FillSelectSchedule((MenuFlyout)_selectSchedule.Flyout);

        AutomationProperties.SetAutomationId(_selectPriority, "tasks.select.priority");
        _selectPriority.Flyout = new MenuFlyout();
        ((MenuFlyout)_selectPriority.Flyout).Opening += (_, _) => FillSelectPriority((MenuFlyout)_selectPriority.Flyout);

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

        _selectBar.Children.Add(_selectSchedule);
        _selectBar.Children.Add(_selectPriority);
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
        _pillsHost = new ScrollViewer
        {
            Content = _pills,
            HorizontalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollMode = ScrollMode.Disabled,
            Padding = new Thickness(16, 4, 16, 8),
        };

        _sidebar.OnPickView = v => SwitchView(v);
        _sidebar.OnNewList = () => _ = PromptNewListAsync([]);
        _sidebar.BuildListMenu = id => _store != null ? ListMenu(_store, id) : new MenuFlyout();

        _weekStrip.OnWeekOffsetChanged = offset => { _upcomingWeekOffset = offset; Render(); };
        _weekStrip.OnPickDay = day => { _upcomingPickedDay = day; Render(); };
        _weekStrip.GetDraggingTaskId = () => _dragging;
        _weekStrip.OnDropTaskOnDay = (taskId, day) =>
        {
            _dragging = null;
            if (_store != null) _ = _store.RescheduleAsync([taskId], day, preserveTime: true, zone: Zone);
        };

        var listScroll = new ScrollViewer { Content = _list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        var center = new Grid();
        center.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        center.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        center.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        center.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        center.Children.Add(bar);
        Grid.SetRow(_pillsHost, 1);
        center.Children.Add(_pillsHost);
        Grid.SetRow(_activeFiltersBar, 2);
        center.Children.Add(_activeFiltersBar);
        Grid.SetRow(listScroll, 3);
        center.Children.Add(listScroll);
        Grid.SetRow(_notice.Bar, 3);
        center.Children.Add(_notice.Bar);

        _pane = new Border
        {
            Width = 440,
            Visibility = Visibility.Collapsed,
            Child = _paneHost,
            BorderThickness = new Thickness(1, 0, 0, 0),
            BorderBrush = Brush("DividerStrokeColorDefaultBrush"),
            Background = Brush("LayerFillColorDefaultBrush"),
        };

        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.Children.Add(_sidebar);
        Grid.SetColumn(center, 1);
        root.Children.Add(center);
        Grid.SetColumn(_pane, 2);
        root.Children.Add(_pane);
        Content = root;

        SizeChanged += (_, _) => Render();
        Accelerator(VirtualKey.F5, VirtualKeyModifiers.None, KeyRefresh);
        Accelerator(VirtualKey.R, VirtualKeyModifiers.Control, KeyRefresh);
        Accelerator(VirtualKey.F, VirtualKeyModifiers.Control, () => _search.Focus(FocusState.Keyboard));
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
        if (AppState.Client is not { } client || TasksHub.For(client) is not { } hub) return;
        _store = hub.Store;
        _ideasStore = hub.Ideas;
        _store.Changed += OnChanged;
        _store.Notice += OnStoreNotice;
        _ideasStore.Changed += OnChanged;
        _ideasStore.Notice += OnIdeaNotice;
        _store.SetVisible(true);
        _ = _store.RefreshAsync();
        _ = _ideasStore.RefreshAsync();
        AppLog.Note("tasks", "page shown");

        if (e.Parameter is PlaceArgs { Argument: string arg } && !string.IsNullOrWhiteSpace(arg))
        {
            if (TodoView.FromKey(arg) is { } targetView)
            {
                _view = targetView;
            }
            else if (GoalBots.PushedGoal(arg) is { } gid)
            {
                _view = TodoView.Goals;
                OpenGoal(gid);
            }
            else if (_store.FindGoal(arg) != null)
            {
                _view = TodoView.Goals;
                OpenGoal(arg);
            }
            else
            {
                OpenTask(arg);
            }
        }
        Render();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _taskPane?.FlushUnsavedEdits();
        _goalPane?.FlushUnsavedEdits();
        _selection.End();
        if (_store != null)
        {
            _store.SetVisible(false);
            _store.Changed -= OnChanged;
            _store.Notice -= OnStoreNotice;
        }
        if (_ideasStore != null)
        {
            _ideasStore.Changed -= OnChanged;
            _ideasStore.Notice -= OnIdeaNotice;
        }
    }

    private void OnChanged() => _ui.TryEnqueue(() => { Render(); _taskPane?.Render(); _goalPane?.Render(); });

    private void SwitchView(TodoView next)
    {
        if (_view == next) return;
        _view = next;
        if (next != TodoView.Upcoming) { _upcomingPickedDay = null; _upcomingWeekOffset = 0; }
        if (next == TodoView.Suggested && _ideasStore != null) _ = _ideasStore.RefreshAsync();
        Render();
    }

    // ------------------------------------------------------------------ drawing

    private IReadOnlyList<string> BotOrder => [.. PageKit.Bots.Select(b => b.Name)];

    private double PaneWidthForSidebar()
    {
        var total = ActualWidth > 0 ? ActualWidth : 1000;
        return _pane.Visibility == Visibility.Visible ? Math.Max(0, total - _pane.Width) : total;
    }

    private void Render()
    {
        if (_store is not { } store) return;
        var now = DateTimeOffset.Now;
        var sections = store.Sections;
        if (_view.ListId is { } id && !sections.Any(s => s.Id == id)) _view = TodoView.Today;
        if (_view == TodoView.Bots && !TodoViews.ShowsBots(store.Tasks)) _view = TodoView.Today;
        if (GoalsAddOn.FallsBack(_view, store.GoalsSupported, store.GoalsNeedAddOn)) _view = TodoView.Today;

        var showSidebar = TasksNavigationLayout.ShouldShowSidebar(true, PaneWidthForSidebar(), _sidebarCollapsed, store.HasList, store.NeedsAddOn);
        _sidebar.Visibility = showSidebar ? Visibility.Visible : Visibility.Collapsed;
        _sidebarToggle.Visibility = store.HasList && !store.NeedsAddOn ? Visibility.Visible : Visibility.Collapsed;
        _pillsHost.Visibility = !showSidebar && store.HasList && !store.NeedsAddOn ? Visibility.Visible : Visibility.Collapsed;
        _compactViewPicker.Visibility = !showSidebar && store.HasList && !store.NeedsAddOn ? Visibility.Visible : Visibility.Collapsed;
        _compactViewPicker.Content = TasksNavigationLayout.Title(_view, sections);
        _barTitle.Text = showSidebar ? TasksNavigationLayout.Title(_view, sections) : TasksCopy.Title;

        if (showSidebar) _sidebar.Render(store, _ideasStore, _view, now, Zone);
        RenderPills(store, now);
        RenderBar(store);
        RenderActiveFiltersBar();

        _list.Children.Clear();
        _openIds = [];
        if (store.NeedsAddOn)
        {
            _list.Children.Add(State("\uEA86", TasksCopy.UpdateAddOn, TasksCopy.UpdateAddOnText(HostWord.UpdateTarget), null, null));
            return;
        }
        if (!store.HasList)
        {
            if (!store.Loading && store.Error is { } reason)
                _list.Children.Add(State("\uE783", TasksCopy.CouldNotLoad, reason, TasksCopy.TryAgain, () => _ = store.RefreshAsync(force: true)));
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
        var hasFilters = _priorityFilter != null || _tagFilter != null;

        if (GoalsAddOn.Locked(_view, searching, store.GoalsSupported))
        {
            _list.Children.Add(GoalsLockedState(store));
            return;
        }

        var goalsFound = searching && RenderFoundGoals(store, now);

        if (_view == TodoView.Goals && !searching)
        {
            RenderGoals(store, now);
            return;
        }

        if (_view == TodoView.Suggested && !searching)
        {
            RenderSuggestedView(store, now);
            return;
        }

        if (_view == TodoView.Today && !searching && !hasFilters)
        {
            RenderTodayCheckInStrip(store, now);
            RenderTodayOffers(store, now);
        }

        if (GoalShelf.Shows(_view, searching, "all", store.GoalsSupported, store.Goals) && !hasFilters)
            _list.Children.Add(GoalShelfView(store, now));

        var tasks = TodoSections.Filtered(store.Tasks, _query, store.Goals, priority: _priorityFilter, tag: _tagFilter);

        // Multi-week strip at the top of Upcoming (with busy dots + drag-drop rescheduling).
        if (_view == TodoView.Upcoming && !searching)
        {
            var busyDays = new HashSet<string>(StringComparer.Ordinal);
            foreach (var g in TodoViews.Groups(tasks, TodoView.Upcoming, sections, BotOrder, now, Zone, store.Settings.Sort))
                if (g.Kind.IsDay && g.Kind.Arg is { } dk) busyDays.Add(dk);
            if (TodoViews.Groups(tasks, TodoView.Today, sections, BotOrder, now, Zone, store.Settings.Sort).Any(g => g.Kind == TodoGroupKind.Today))
                busyDays.Add(TodoViews.DayKey(TodoDates.LocalDay(now, Zone)));
            _weekStrip.Render(_upcomingWeekOffset, _upcomingPickedDay, busyDays, now, Zone);
            _list.Children.Add(_weekStrip);
        }

        if (store.Tasks.Count == 0 && !goalsFound)
        {
            _list.Children.Add(State("\uE762", TasksCopy.NoTasks, TasksCopy.NothingText, TasksCopy.NewTask, NewTask));
            return;
        }

        var pausedGoals = GoalViews.Groups(store.Goals).Someday.Select(g => g.Id).ToHashSet(StringComparer.Ordinal);
        List<TodoGroup> groups;
        if (searching)
            groups = TodoViews.SearchGroups(tasks, Zone);
        else if (_view == TodoView.Upcoming && _upcomingPickedDay is { } pickedDay)
            groups = TodoViews.DayGroups(tasks, pickedDay, sections, BotOrder, now, Zone, store.Settings.Sort, pausedGoals);
        else
            groups = TodoViews.Groups(tasks, _view, sections, BotOrder, now, Zone, store.Settings.Sort, pausedGoals);

        if (groups.Count == 0)
        {
            if (goalsFound) return;
            var empty = searching
                ? $"No Results for “{_query.Trim()}”"
                : hasFilters
                    ? "No tasks match the active filters."
                    : _view == TodoView.Upcoming && _upcomingPickedDay is { } pd
                        ? TodoViews.DayEmptyText(pd, now, Zone)
                        : TodoViews.EmptyText(_view, ListName(_view.ListId));
            var t = Text(empty, 14, color: Secondary);
            t.Margin = new Thickness(4, 16, 4, 0);
            _list.Children.Add(t);
            return;
        }

        foreach (var group in groups)
        {
            if (TodoViews.PageHeading(group.Kind, _view, searching, now, Zone, sections, BotName) is { } h)
                _list.Children.Add(GroupHeading(group, h.Title, h.Detail, TodoViews.DoneFold(group.Kind, _doneOpen, searching)));
            if (!TodoViews.ShowsRows(group.Kind, _doneOpen, searching)) continue;
            var arranging = group.Kind == TodoGroupKind.Open && _view.ListId != null && !searching && !hasFilters;
            if (arranging) _openIds = [.. group.Tasks.Select(t => t.Id)];
            var allowDayDrag = _view == TodoView.Upcoming && !searching && !store.ReadOnlyGateway && !_selection.Active;
            foreach (var task in group.Tasks) _list.Children.Add(RowView(task, group.Kind, now, arranging, allowDayDrag));
            if (group.Kind.IsNext && group.More > 0 && group.Kind.Arg is { } list)
            {
                var more = new HyperlinkButton { Content = TodoViews.MoreLine(group.More, ListName(list) ?? "List") + " ›" };
                more.Click += (_, _) => SwitchView(TodoView.List(list));
                _list.Children.Add(more);
            }
        }
    }

    private void RenderActiveFiltersBar()
    {
        _activeFiltersBar.Children.Clear();
        if (_priorityFilter == null && _tagFilter == null)
        {
            _activeFiltersBar.Visibility = Visibility.Collapsed;
            return;
        }
        _activeFiltersBar.Visibility = Visibility.Visible;

        if (_priorityFilter is { } pri)
        {
            var chip = Quiet($"Priority: {TodoViews.PriorityWord(pri)}  ✕", () => { _priorityFilter = null; Render(); });
            AutomationProperties.SetName(chip, $"Clear {TodoViews.PriorityWord(pri)} priority filter");
            AutomationProperties.SetAutomationId(chip, "tasks.filter.chip.priority");
            _activeFiltersBar.Children.Add(chip);
        }
        if (_tagFilter is { } tag)
        {
            var chip = Quiet($"#{tag}  ✕", () => { _tagFilter = null; Render(); });
            AutomationProperties.SetName(chip, $"Clear tag {tag} filter");
            AutomationProperties.SetAutomationId(chip, "tasks.filter.chip.tag");
            _activeFiltersBar.Children.Add(chip);
        }
        var clearAll = Quiet("Clear Filters", () => { _priorityFilter = null; _tagFilter = null; Render(); });
        AutomationProperties.SetAutomationId(clearAll, "tasks.filter.clear");
        _activeFiltersBar.Children.Add(clearAll);
    }

    /// Dedicated Suggested view (`1da255c07` / `f3a9b867a`) with Sources banner, Look Now, Ideas Settings, and expandable cards.
    private void RenderSuggestedView(TasksStore store, DateTimeOffset now)
    {
        if (_ideasStore is not { } ideasStore) return;
        var page = ideasStore.Page;
        var visible = ideasStore.VisibleIdeas;
        var roster = PageKit.Bots.Select(b => (Id: b.Name, Name: BotName(b.Name))).ToList();
        var botsLabel = TaskIdeasSummary.ActiveBotsLabel(store.Settings.ActiveIdeasBots, roster);
        var sources = store.Settings.IdeasSources ?? page.Sources ?? new TodoIdeasSources();
        var connectors = page.AvailableSources?.Connectors ?? [];
        var sourcesLabel = TaskIdeasSummary.ActiveSourcesLabel(sources, connectors);
        var isOn = page.On || store.Settings.Ideas == true;
        var looking = ideasStore.Looking || page.Running;

        // "Checking <sourcesSummary>" Sources > banner
        var bannerGrid = new Grid { ColumnSpacing = 12 };
        bannerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bannerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var bannerInfo = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        bannerInfo.Children.Add(Text(isOn ? $"Checking {sourcesLabel}" : "Task suggestions are off", 13.5, bold: true));
        if (isOn)
        {
            var sub = looking
                ? "Looking through your recent activity…"
                : page.RanAt is { Length: > 0 } ranAt && TodoDates.Moment(ranAt) is { } dt
                    ? $"Suggested by {botsLabel} · Last checked {TodoWords.Ago(ranAt, now, Zone)}"
                    : $"Suggested by {botsLabel}";
            bannerInfo.Children.Add(Text(sub, 12, color: Secondary));
        }
        else
        {
            bannerInfo.Children.Add(Text(TodoSettingsCopy.IdeasFooter(botsLabel), 12, color: Secondary));
        }
        bannerGrid.Children.Add(bannerInfo);

        var bannerTools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (isOn)
        {
            var sourcesBtn = Quiet("Sources ›", () => _ = IdeasSourcesDialog.PresentAsync(XamlRoot, store, ideasStore));
            AutomationProperties.SetAutomationId(sourcesBtn, "tasks.suggested.sources");
            bannerTools.Children.Add(sourcesBtn);

            var lookBtn = Push(looking ? "Looking…" : "Look Now", () => _ = ideasStore.LookNowAsync(), accent: false);
            lookBtn.IsEnabled = !looking && !store.ReadOnlyGateway;
            AutomationProperties.SetAutomationId(lookBtn, "tasks.suggested.look-now");
            bannerTools.Children.Add(lookBtn);

            var settingsBtn = Quiet("Settings…", () => _ = TasksSettingsDialog.PresentAsync(XamlRoot, store, ideasStore));
            bannerTools.Children.Add(settingsBtn);
        }
        else
        {
            var turnOnBtn = Push("Turn On Ideas", () => _ = ideasStore.SetOnAsync(true, store), accent: true);
            turnOnBtn.IsEnabled = !store.ReadOnlyGateway;
            bannerTools.Children.Add(turnOnBtn);
        }
        Grid.SetColumn(bannerTools, 1);
        bannerGrid.Children.Add(bannerTools);

        var bannerCard = Card(bannerGrid, 12);
        bannerCard.Margin = new Thickness(0, 4, 0, 10);
        AutomationProperties.SetAutomationId(bannerCard, "tasks.suggested.banner");
        _list.Children.Add(bannerCard);

        if (!isOn) return;

        if (visible.Count == 0)
        {
            var empty = Text(looking ? "Looking through recent activity…" : TodoViews.EmptyText(TodoView.Suggested, null), 14, color: Secondary);
            empty.Margin = new Thickness(4, 16, 4, 0);
            _list.Children.Add(empty);
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
                stack.Children.Add(Text(item.Why, 12.5, color: Secondary));
            if (expanded && !string.IsNullOrWhiteSpace(item.Help))
                stack.Children.Add(Text($"{BotName(item.Bot ?? page.Bot)} can help: {item.Help}", 12, color: Accent));
            if (expanded)
            {
                var origin = !string.IsNullOrWhiteSpace(item.Source) ? item.Source : item.From?.Line(now, Zone);
                if (!string.IsNullOrWhiteSpace(origin))
                    stack.Children.Add(Text("From " + origin, 11.5, color: Tertiary));
            }

            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var addOnly = Push("Add", () => _ = ideasStore.AddAsync(item, letBotStart: false, store), accent: !item.BotHelps);
            addOnly.IsEnabled = !store.ReadOnlyGateway;
            actions.Children.Add(addOnly);
            if (item.BotHelps)
            {
                var addStart = Push($"Add & Let {BotName(item.Bot ?? page.Bot)} Start", () => _ = ideasStore.AddAsync(item, letBotStart: true, store), accent: true);
                addStart.IsEnabled = !store.ReadOnlyGateway;
                actions.Children.Add(addStart);
            }
            var dismiss = Quiet("Dismiss", () => _ = DismissIdeaWithUndoAsync(ideasStore, item));
            dismiss.IsEnabled = !store.ReadOnlyGateway;
            actions.Children.Add(dismiss);
            stack.Children.Add(actions);

            var card = Card(stack, 12);
            card.Margin = new Thickness(0, 3, 0, 3);
            AutomationProperties.SetAutomationId(card, "tasks.idea." + item.Id);
            _list.Children.Add(card);
        }
    }

    private FrameworkElement GroupHeading(TodoGroup group, string title, string? detail, string? fold)
    {
        var head = new TextBlock { FontSize = 11.5, CharacterSpacing = 45, VerticalAlignment = VerticalAlignment.Center };
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

        var row = new Grid { Margin = new Thickness(6, 18, 8, 6) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(head);
        AutomationProperties.SetAutomationId(row, TodoViews.SectionAutomationId(title));

        if (group.Kind == TodoGroupKind.Overdue && _store is { ReadOnlyGateway: false } store && group.Tasks.Count > 0)
        {
            var overdueIds = group.Tasks.Select(t => t.Id).ToList();
            var rescheduleBtn = new DropDownButton { Content = TasksCopy.Reschedule, Padding = new Thickness(8, 2, 8, 2), FontSize = 12 };
            AutomationProperties.SetAutomationId(rescheduleBtn, "tasks.overdue.reschedule");
            var menu = new MenuFlyout();
            var now = DateTimeOffset.Now;
            menu.Items.Add(Item(TasksCopy.Today, "\uE787", () => _ = store.RescheduleAsync(overdueIds, now, preserveTime: true, zone: Zone)));
            menu.Items.Add(Item(TasksCopy.Tomorrow, "\uE787", () => _ = store.RescheduleAsync(overdueIds, now.AddDays(1), preserveTime: true, zone: Zone)));
            menu.Items.Add(Item(TasksCopy.NextWeek, "\uE787", () => _ = store.RescheduleAsync(overdueIds, now.AddDays(7), preserveTime: true, zone: Zone)));
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Item(TasksCopy.ChooseDate, "\uE787", () => _ = ChooseDateBatchAsync(store, overdueIds)));
            rescheduleBtn.Flyout = menu;
            Grid.SetColumn(rescheduleBtn, 1);
            row.Children.Add(rescheduleBtn);
        }
        else if (fold != null)
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

    private void FillCompactViewMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        if (_store is not { } store) return;
        var goalsPill = GoalsAddOn.Pill(store.GoalsSupported, store.GoalsNeedAddOn, store.Goals);
        void AddChoice(TodoView v, string title)
        {
            var item = new ToggleMenuFlyoutItem { Text = title, IsChecked = _view == v };
            item.Click += (_, _) => SwitchView(v);
            menu.Items.Add(item);
        }
        AddChoice(TodoView.Today, TasksCopy.Today);
        AddChoice(TodoView.Upcoming, TasksCopy.Upcoming);
        AddChoice(TodoView.Inbox, TasksCopy.Inbox);
        if (goalsPill.Shows) AddChoice(TodoView.Goals, GoalsCopy.Goals);
        if (store.Sections.Count > 0)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            foreach (var sec in store.Sections) AddChoice(TodoView.List(sec.Id), sec.Name);
        }
        var showSuggested = _ideasStore != null && (store.Settings.Ideas != null || _ideasStore.Page.On || _ideasStore.VisibleIdeas.Count > 0);
        var showBots = TodoViews.ShowsBots(store.Tasks);
        if (showSuggested || showBots)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            if (showSuggested) AddChoice(TodoView.Suggested, TasksCopy.Suggested);
            if (showBots) AddChoice(TodoView.Bots, TasksCopy.BotsTasks);
        }
    }

    private void RenderPills(TasksStore store, DateTimeOffset now)
    {
        _pills.Children.Clear();
        if (!store.HasList || store.NeedsAddOn) return;
        var sections = store.Sections;
        var goalsPill = GoalsAddOn.Pill(store.GoalsSupported, store.GoalsNeedAddOn, store.Goals);
        int? Count(TodoView v) => v == TodoView.Goals ? goalsPill.Count
            : v == TodoView.Suggested ? (_ideasStore?.Loaded == true ? _ideasStore.VisibleIdeas.Count : store.IdeasCount)
            : TodoViews.OpenCount(store.Tasks, v, sections, now, Zone);
        var views = new List<(TodoView View, string Title)> { (TodoView.Today, TasksCopy.Today), (TodoView.Upcoming, TasksCopy.Upcoming), (TodoView.Inbox, TasksCopy.Inbox) };
        if (goalsPill.Shows) views.Insert(0, (TodoView.Goals, GoalsCopy.Goals));
        views.AddRange(sections.Select(s => (TodoView.List(s.Id), s.Name)));
        if (_ideasStore != null && (store.Settings.Ideas != null || _ideasStore.Page.On || _ideasStore.VisibleIdeas.Count > 0))
            views.Add((TodoView.Suggested, TasksCopy.Suggested));
        if (TodoViews.ShowsBots(store.Tasks)) views.Add((TodoView.Bots, TasksCopy.Bots));
        foreach (var (view, title) in views)
        {
            var picked = view == _view;
            var words = new TextBlock { FontSize = 14 };
            words.Inlines.Add(new Run { Text = title, FontWeight = FontWeights.SemiBold });
            var count = Count(view);
            var contrast = ContrastPair(Hermes.Core.Settings.ContrastTheme.PillSurface(picked));
            if (TasksCopy.PillDetail(count) is { } detail)
                words.Inlines.Add(new Run { Text = "  " + detail, Foreground = contrast?.Ink ?? (picked ? Brush("TextOnAccentFillColorSecondaryBrush") : Secondary) });
            var pill = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = words, IsChecked = picked, CornerRadius = new CornerRadius(16), Padding = new Thickness(12, 5, 12, 6) };
            if (contrast is { } pair) ContrastPill(pill, "ToggleButton", picked ? "Checked" : "", pair, words);
            AutomationProperties.SetName(pill, TasksCopy.PillName(title, count));
            AutomationProperties.SetAutomationId(pill, "tasks.view." + view.Key);
            var v = view;
            pill.Click += (_, _) => SwitchView(v);
            if (view.ListId is { } listId && store.EditsLists) pill.ContextFlyout = ListMenu(store, listId);
            _pills.Children.Add(pill);
        }
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

    internal static (SolidColorBrush Fill, SolidColorBrush Ink, SolidColorBrush Edge)? ContrastPair(Hermes.Core.Settings.ContrastTheme.Surface surface)
    {
        if (!HermesHQ.Features.Settings.ThemeService.SystemHighContrast) return null;
        var want = Hermes.Core.Settings.ContrastTheme.For(surface);
        return HermesHQ.Features.Settings.ThemeService.SystemBrush(want.Fill) is { } fill
            && HermesHQ.Features.Settings.ThemeService.SystemBrush(want.Ink) is { } ink
            && HermesHQ.Features.Settings.ThemeService.SystemBrush(want.Edge) is { } edge ? (fill, ink, edge) : null;
    }

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

    private MenuFlyout ListMenu(TasksStore store, string id)
    {
        var menu = new MenuFlyout();
        var at = store.Sections.ToList().FindIndex(s => s.Id == id);
        var sectionName = store.Sections.FirstOrDefault(s => s.Id == id)?.Name ?? TodoListCopy.FallbackName;
        foreach (var entry in TodoListCopy.Menu(Math.Max(at, 0), store.Sections.Count))
        {
            if (entry == TodoListMenuItem.Divider)
            {
                menu.Items.Add(FavoritesPinAction.ForTaskView(TodoView.List(id).Key, sectionName));
                menu.Items.Add(new MenuFlyoutSeparator());
                continue;
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

    // ------------------------------------------------------------------ your lists

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

    private async Task PromptNewListAsync(List<string> ids, Action? after = null)
    {
        if (_store is not { } store) return;
        if (store.ReadOnlyGateway) { _notice.Show(KanbanRest.ReadOnlyNotice); return; }
        if (await AskNameAsync(TodoListCopy.NewList, TodoListCopy.NewListMessage, "", TodoListCopy.Add) is not { } name) return;
        if (await store.AddSectionAsync(name) is not { } made) return;
        if (ids.Count > 0) await store.MoveAsync(ids, made.Id);
        after?.Invoke();
        SwitchView(TodoView.List(made.Id));
    }

    private async Task RenameListAsync(string id)
    {
        if (_store is not { } store || store.Sections.FirstOrDefault(s => s.Id == id) is not { } section) return;
        if (await AskNameAsync(TodoListCopy.RenameList, null, section.Name, TodoListCopy.Save) is not { } name) return;
        await store.RenameSectionAsync(id, name);
    }

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
            grid.Children.Add(new FontIcon { Glyph = "\uE73E", FontSize = 11, Foreground = Brush("TextOnAccentFillColorPrimaryBrush") });
        }
        var button = new Button { Content = grid, Padding = new Thickness(2), Style = Style("QuietButtonStyle"), VerticalAlignment = VerticalAlignment.Top };
        AutomationProperties.SetName(button, task.IsDone ? "Done. Open it again" : TasksCopy.MarkDone);
        button.Click += (_, _) => _ = toggle();
        button.Tapped += (_, e) => e.Handled = true;
        return button;
    }

    private FrameworkElement RowView(TodoTask task, TodoGroupKind kind, DateTimeOffset now, bool arranging = false, bool allowDayDrag = false)
    {
        var row = RowBody(task, kind, now, arranging, allowDayDrag);
        var host = new ContentControl
        {
            Content = row, IsTabStop = true, UseSystemFocusVisuals = true,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch,
        };
        AutomationProperties.SetAutomationId(host, Hermes.Core.Shell.KeyboardOnlyWalkProof.TaskRowPrefix + task.Id);
        AutomationProperties.SetName(host, AutomationProperties.GetName(row));
        host.KeyDown += (_, e) =>
        {
            if (e.Key is not (VirtualKey.Enter or VirtualKey.Space)) return;
            e.Handled = true;
            if (_selection.Active) TogglePicked(task.Id); else OpenTask(task.Id);
        };
        return host;
    }

    private FrameworkElement RowBody(TodoTask task, TodoGroupKind kind, DateTimeOffset now, bool arranging, bool allowDayDrag)
    {
        var words = TodoViews.Row(task, kind, now, Zone, BotName);
        var contentWidth = PaneWidthForSidebar() - (_sidebar.Visibility == Visibility.Visible ? TasksNavigationLayout.SidebarWidth : 0);
        var wide = ActualWidth <= 0 || TasksNavigationLayout.ShouldUseTable(true, contentWidth);
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(6, wide ? 5 : 6, 8, wide ? 5 : 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (wide)
        {
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
        if (!task.IsDone && TodoViews.PriorityMark(task.Priority) is { } mark)
        {
            name.Inlines.Add(new Run
            {
                Text = mark + " ",
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
            var picked = _selection.IsPicked(task.Id);
            AutomationProperties.SetItemStatus(row, picked ? "Selected" : "");
            row.Tapped += (_, _) => TogglePicked(task.Id);
            return row;
        }
        row.Tapped += (_, _) => OpenTask(task.Id);
        row.ContextFlyout = RowMenu(task);
        if (arranging) AllowArrange(row, task);
        else if (allowDayDrag && !task.IsDone)
        {
            row.CanDrag = true;
            row.DragStarting += (_, e) =>
            {
                _dragging = task.Id;
                e.Data.SetText(TodoWeekStripView.DragPrefix + task.Id);
                e.Data.RequestedOperation = DataPackageOperation.Move;
            };
            row.DropCompleted += (_, _) => _dragging = null;
        }
        return row;
    }

    private MenuFlyout RowMenu(TodoTask task)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(Item(TasksCopy.OpenTask, "\uE8A7", () => OpenTask(task.Id)));
        menu.Items.Add(Item(task.IsDone ? TasksCopy.MarkNotDone : TasksCopy.MarkDone, task.IsDone ? "\uEA3A" : "\uE73E", () => _ = ToggleDone(task)));

        if (_store is { } store)
        {
            // Schedule submenu
            var sched = new MenuFlyoutSubItem { Text = TasksCopy.Schedule, Icon = new FontIcon { Glyph = "\uE787" } };
            var now = DateTimeOffset.Now;
            sched.Items.Add(Item(TasksCopy.Today, "\uE787", () => _ = store.RescheduleAsync([task.Id], now, preserveTime: true, zone: Zone)));
            sched.Items.Add(Item(TasksCopy.Tomorrow, "\uE787", () => _ = store.RescheduleAsync([task.Id], now.AddDays(1), preserveTime: true, zone: Zone)));
            sched.Items.Add(Item(TasksCopy.NextWeek, "\uE787", () => _ = store.RescheduleAsync([task.Id], now.AddDays(7), preserveTime: true, zone: Zone)));
            sched.Items.Add(Item(TasksCopy.ChooseDate, "\uE787", () => _ = ChooseDateBatchAsync(store, [task.Id])));
            if (task.Due != null)
            {
                sched.Items.Add(new MenuFlyoutSeparator());
                sched.Items.Add(Item(TasksCopy.NoDueDate, "\uE711", () => _ = store.RescheduleAsync([task.Id], null)));
            }
            menu.Items.Add(sched);

            // Priority submenu
            if (store.FieldsSupported)
            {
                var pri = new MenuFlyoutSubItem { Text = TasksCopy.Priority, Icon = new FontIcon { Glyph = "\uE7C1" } };
                foreach (var level in new[] { 1, 2, 3, 0 })
                {
                    var l = level;
                    var t = new ToggleMenuFlyoutItem { Text = l == 0 ? TasksCopy.NoPriority : TodoViews.PriorityWord(l), IsChecked = task.Priority == l };
                    t.Click += (_, _) => _ = store.SetPriorityAsync([task.Id], l);
                    pri.Items.Add(t);
                }
                menu.Items.Add(pri);
            }

            // Assign submenu
            var assign = new MenuFlyoutSubItem { Text = TasksCopy.Assign, Icon = new FontIcon { Glyph = "\uE77B" } };
            var meItem = new ToggleMenuFlyoutItem { Text = TasksCopy.JustMe, IsChecked = task.WhoKind == TodoWho.Me };
            meItem.Click += (_, _) => _ = store.PatchAsync(task.Id, new JsonObject
            {
                ["who"] = "me", ["bot"] = null,
                ["steps"] = TodoWire.Steps(task.Steps.Select(s => s with { Who = "me" })),
            });
            assign.Items.Add(meItem);
            if (PageKit.Bots.Count > 0)
            {
                var withMe = new MenuFlyoutSubItem { Text = TasksCopy.WithMe };
                var byItself = new MenuFlyoutSubItem { Text = TasksCopy.ByItself };
                foreach (var bot in PageKit.Bots)
                {
                    var name = bot.Name;
                    var w = new ToggleMenuFlyoutItem { Text = bot.DisplayName, IsChecked = task.WhoKind == TodoWho.Together && task.Helper == name };
                    w.Click += (_, _) => _ = store.PatchAsync(task.Id, new JsonObject { ["who"] = "together", ["bot"] = name });
                    withMe.Items.Add(w);

                    var a = new ToggleMenuFlyoutItem { Text = bot.DisplayName, IsChecked = task.WhoKind == TodoWho.Bot && task.Helper == name };
                    a.Click += (_, _) => _ = store.PatchAsync(task.Id, new JsonObject { ["who"] = "bot", ["bot"] = name });
                    byItself.Items.Add(a);
                }
                assign.Items.Add(withMe);
                assign.Items.Add(byItself);
            }
            menu.Items.Add(assign);

            if (store.Sections.Count > 0 || store.EditsLists)
            {
                var move = new MenuFlyoutSubItem { Text = TasksCopy.MoveTo, Icon = new FontIcon { Glyph = "\uE8B7" } };
                AddMoveChoices(move.Items, store, [task.Id], null);
                menu.Items.Add(move);
            }

            if (AddToGoalMenu(store, task) is { } goalMenu) menu.Items.Add(goalMenu);

            menu.Items.Add(Item(TasksCopy.Duplicate, "\uE8C8", () => _ = DuplicateTaskAsync(store, task.Id)));
        }

        var select = Item(TodoSelection.RowMenuTitle, "\uE73A", () => { _selection.StartWith(task.Id); Render(); });
        AutomationProperties.SetAutomationId(select, "tasks.select.row");
        menu.Items.Add(select);
        menu.Items.Add(new MenuFlyoutSeparator());
        var delete = Item(TasksCopy.Delete, "\uE74D", () => _ = ConfirmDeleteAsync(task.Id));
        delete.Foreground = Critical;
        menu.Items.Add(delete);
        return menu;
    }

    private async Task DuplicateTaskAsync(TasksStore store, string id)
    {
        if (await store.DuplicateAsync(id) is { } made)
            _notice.Show($"Duplicated “{(made.Title.Length == 0 ? TasksCopy.Untitled : made.Title)}”");
    }

    // ------------------------------------------------------------------ ⋯ menu, Filter, Sort By, Select, drag

    private void FillMoreMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        if (_store is not { } store) return;

        // Priority & Tag filters (when fields supported and viewing tasks)
        if (store.FieldsSupported && _view != TodoView.Suggested && _view != TodoView.Goals)
        {
            var priSub = new MenuFlyoutSubItem { Text = TasksCopy.Priority, Icon = new FontIcon { Glyph = "\uE7C1" } };
            AutomationProperties.SetAutomationId(priSub, "tasks.filter.priority");
            foreach (var (level, label) in new (int?, string)[] { (null, "Any Priority"), (1, "High"), (2, "Medium"), (3, "Low") })
            {
                var l = level;
                var item = new RadioMenuFlyoutItem { Text = label, GroupName = "tasks-filter-pri", IsChecked = _priorityFilter == l };
                item.Click += (_, _) => { _priorityFilter = l; Render(); };
                priSub.Items.Add(item);
            }
            menu.Items.Add(priSub);

            var tags = TodoViews.AllTags(store.Tasks);
            if (tags.Count > 0 || _tagFilter != null)
            {
                var tagSub = new MenuFlyoutSubItem { Text = "Tag", Icon = new FontIcon { Glyph = "\uE8EC" } };
                AutomationProperties.SetAutomationId(tagSub, "tasks.filter.tag");
                var allItem = new RadioMenuFlyoutItem { Text = "All Tags", GroupName = "tasks-filter-tag", IsChecked = _tagFilter == null };
                allItem.Click += (_, _) => { _tagFilter = null; Render(); };
                tagSub.Items.Add(allItem);
                foreach (var t in tags)
                {
                    var tag = t;
                    var ti = new RadioMenuFlyoutItem
                    {
                        Text = "#" + tag,
                        GroupName = "tasks-filter-tag",
                        IsChecked = string.Equals(_tagFilter, tag, StringComparison.OrdinalIgnoreCase),
                    };
                    ti.Click += (_, _) => { _tagFilter = tag; Render(); };
                    tagSub.Items.Add(ti);
                }
                menu.Items.Add(tagSub);
            }
            menu.Items.Add(new MenuFlyoutSeparator());
        }

        if (TodoSortBy.Shows(_view) || _view == TodoView.Today || _view == TodoView.Inbox)
        {
            var sort = store.Settings.Sort;
            var sub = new MenuFlyoutSubItem { Text = TodoSortBy.Title, Icon = new FontIcon { Glyph = "\uE8CB" } };
            if (TodoSortBy.Subtitle(sort) is { } subtitle)
            {
                AutomationProperties.SetHelpText(sub, subtitle);
                ToolTipService.SetToolTip(sub, subtitle);
            }
            AutomationProperties.SetAutomationId(sub, "tasks.sort.menu");
            foreach (var option in TodoSortBy.Options(store.FieldsSupported, sort))
            {
                var key = option.Key;
                var optTitle = key == "smart" && _view.ListId == null ? "Default" : option.Title;
                var item = new RadioMenuFlyoutItem { Text = optTitle, GroupName = "tasks-sort", IsChecked = sort == key, Icon = new FontIcon { Glyph = option.Glyph } };
                AutomationProperties.SetAutomationId(item, "tasks.sort." + key);
                item.Click += (_, _) => _ = store.SetSortAsync(key);
                sub.Items.Add(item);
            }
            menu.Items.Add(sub);
        }

        if (_view != TodoView.Suggested && _view != TodoView.Goals)
        {
            var select = Item(TodoSelection.MenuTitle, "\uE73A", () => SetSelecting(true));
            AutomationProperties.SetAutomationId(select, "tasks.select.start");
            menu.Items.Add(select);
        }

        menu.Items.Add(FavoritesPinAction.ForTaskView(_view.Key, TasksNavigationLayout.Title(_view, store.Sections)));
        menu.Items.Add(new MenuFlyoutSeparator());

        var logbook = Item(TasksCopy.CompletedLogbook, "\uE82D", () => _ = TaskLogbookDialog.PresentAsync(XamlRoot, store, OpenTask));
        AutomationProperties.SetAutomationId(logbook, "tasks.logbook.open");
        menu.Items.Add(logbook);

        var settings = Item(TodoSettingsCopy.MenuTitle, "\uE713", () => _ = TasksSettingsDialog.PresentAsync(XamlRoot, store, _ideasStore));
        AutomationProperties.SetAutomationId(settings, "tasks.settings.open");
        menu.Items.Add(settings);
    }

    private void RenderBar(TasksStore store)
    {
        var on = _selection.Active;
        _tools.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        _selectBar.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        _tools.IsHitTestVisible = !store.NeedsAddOn;
        _tools.Opacity = store.NeedsAddOn ? 0.4 : 1;
        var addLabel = GoalsAddOn.AddLabel(_view, store.GoalsNeedAddOn);
        AutomationProperties.SetName(_add, addLabel);
        ToolTipService.SetToolTip(_add, addLabel);
        if (!on) return;
        var can = _selection.CanAct(SelectedIds().Count, store.ReadOnlyGateway);
        _selectSchedule.IsEnabled = _selectMove.IsEnabled = _selectDone.IsEnabled = _selectDelete.IsEnabled = can;
        _selectPriority.Visibility = store.FieldsSupported ? Visibility.Visible : Visibility.Collapsed;
        _selectPriority.IsEnabled = can;
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
        items.Add(new MenuFlyoutSeparator());
        var make = Item(TodoListCopy.NewListEllipsis, "\uE710", () => _ = PromptNewListAsync(ids, after));
        AutomationProperties.SetAutomationId(make, "tasks.move.new-list");
        items.Add(make);
    }

    private void FillSelectSchedule(MenuFlyout menu)
    {
        menu.Items.Clear();
        if (_store is not { } store || SelectedIds() is not { Count: > 0 } ids) return;
        var now = DateTimeOffset.Now;
        menu.Items.Add(Item(TasksCopy.Today, "\uE787", () => { _ = store.RescheduleAsync(ids, now, preserveTime: true, zone: Zone); SetSelecting(false); }));
        menu.Items.Add(Item(TasksCopy.Tomorrow, "\uE787", () => { _ = store.RescheduleAsync(ids, now.AddDays(1), preserveTime: true, zone: Zone); SetSelecting(false); }));
        menu.Items.Add(Item(TasksCopy.NextWeek, "\uE787", () => { _ = store.RescheduleAsync(ids, now.AddDays(7), preserveTime: true, zone: Zone); SetSelecting(false); }));
        menu.Items.Add(Item(TasksCopy.ChooseDate, "\uE787", () => _ = ChooseDateBatchAsync(store, ids, () => SetSelecting(false))));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(TasksCopy.NoDueDate, "\uE711", () => { _ = store.RescheduleAsync(ids, null); SetSelecting(false); }));
    }

    private void FillSelectPriority(MenuFlyout menu)
    {
        menu.Items.Clear();
        if (_store is not { } store || SelectedIds() is not { Count: > 0 } ids) return;
        foreach (var level in new[] { 1, 2, 3, 0 })
        {
            var l = level;
            menu.Items.Add(Item(l == 0 ? TasksCopy.NoPriority : TodoViews.PriorityWord(l), "\uE7C1", () =>
            {
                _ = store.SetPriorityAsync(ids, l);
                SetSelecting(false);
            }));
        }
    }

    private async Task ChooseDateBatchAsync(TasksStore store, List<string> ids, Action? after = null)
    {
        var picker = new CalendarDatePicker { Date = DateTimeOffset.Now.AddDays(1), HorizontalAlignment = HorizontalAlignment.Stretch };
        var dialog = new ContentDialog
        {
            Title = TasksCopy.Reschedule,
            Content = picker,
            PrimaryButtonText = KanbanCopy.Set,
            CloseButtonText = TasksCopy.Cancel,
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary || picker.Date is not { } picked) return;
        await store.RescheduleAsync(ids, picked, preserveTime: true, zone: Zone);
        after?.Invoke();
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

    private void AllowArrange(Border row, TodoTask task)
    {
        if (_store is not { } store || !TodoArrange.CanLift(task, _view, _query.Trim().Length > 0, _selection.Active, store.ReadOnlyGateway)) return;
        row.CanDrag = true;
        row.AllowDrop = true;
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
            _dropPlace.Reset();
            ClearDropMark();
        }
        row.DragStarting += (_, e) =>
        {
            _dragging = task.Id;
            _dropPlace.Reset();
            e.Data.SetText(task.Title);
            e.Data.RequestedOperation = DataPackageOperation.Move;
        };
        row.DropCompleted += (_, _) => EndDrag();
        row.DragOver += (_, e) =>
        {
            if (_dragging == null) return;
            var y = e.GetPosition(row).Y;
            if (TodoArrange.DropIndex(_openIds, task.Id, y, row.ActualHeight) is not { } at) return;
            _ = _dropPlace.Update(at);
            ShowDropMark(mark, under: at > _openIds.IndexOf(task.Id));
            e.AcceptedOperation = DataPackageOperation.Move;
            e.Handled = true;
        };
        row.DragLeave += (_, _) =>
        {
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
            _ = store.MoveAsync([plan.Id], plan.List, plan.Position);
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

    internal void ShowNotice(string text, int seconds = 4) => _notice.Show(text, seconds);

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
                    if (itemCard != null) { itemCard.IsHitTestVisible = false; itemCard.Opacity = 0.45; }
                    _ = RunAndRemoveAsync();
                    async Task RunAndRemoveAsync()
                    {
                        try { await work(); }
                        catch (Exception ex) { AppLog.Error("tasks", ex); }
                        if (itemCard != null) panel.Children.Remove(itemCard);
                    }
                }
                btns.Children.Add(Quiet("Today", () => DismissRow(() => store.RescheduleAsync([task.Id], now, preserveTime: true, zone: Zone))));
                btns.Children.Add(Quiet("Tomorrow", () => DismissRow(() => store.RescheduleAsync([task.Id], now.AddDays(1), preserveTime: true, zone: Zone))));
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
            if (o.IsGoalOffer)
            {
                var builtOn = GoalOffers.BuiltOnLines(o);
                if (builtOn.Count > 0)
                {
                    stack.Children.Add(Text(GoalOffers.BuiltOnHeader, 12, bold: true, color: Secondary));
                    foreach (var line in builtOn) stack.Children.Add(Text("• " + line, 12, color: Secondary));
                }
                var setupRows = GoalOffers.SetupRows(o, now, Zone);
                if (setupRows.Count > 0)
                {
                    stack.Children.Add(Text(GoalOffers.SetupHeader, 12, bold: true, color: Secondary));
                    foreach (var row in setupRows) stack.Children.Add(Text($"{row.Label}: {row.Value}", 12));
                }
                if (o.Milestones.Count > 0)
                {
                    foreach (var ms in o.Milestones.Take(3)) stack.Children.Add(Text("□  " + ms.Title, 12.5));
                    if (o.Milestones.Count > 3) stack.Children.Add(Text($"{o.Milestones.Count - 3} more milestones ›", 12, color: Secondary));
                }
            }
            if (o.AllTasks.Count > 0)
            {
                foreach (var t in o.AllTasks.Take(3))
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
                if (o.AllTasks.Count > 3)
                    stack.Children.Add(Text($"{o.AllTasks.Count - 3} more ›", 12, color: Secondary));
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
        if (action is TodoOfferAction.Accept or TodoOfferAction.AcceptNoList or TodoOfferAction.AcceptNoPlan or TodoOfferAction.AcceptJustTasks)
        {
            _notice.Show("Offer accepted.", seconds: 6, action: "Undo", onAction: () => _ = store.AnswerOfferAsync(offer.Id, TodoOfferAction.Undo));
        }
        else if (action == TodoOfferAction.Decline)
        {
            _notice.Show("Offer dismissed.", seconds: 6, action: "Undo", onAction: () => _ = store.AnswerOfferAsync(offer.Id, TodoOfferAction.Undo));
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
        _taskPane?.FlushUnsavedEdits();
        _goalPane?.FlushUnsavedEdits();
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
        _taskPane?.FlushUnsavedEdits();
        _goalPane?.FlushUnsavedEdits();
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
        _taskPane?.FlushUnsavedEdits();
        _goalPane?.FlushUnsavedEdits();
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
        switch (GoalsAddOn.AddAction(_view, _query.Trim().Length > 0, store.GoalsSupported, store.GoalsNeedAddOn))
        {
            case GoalsAddAction.NewGoal: NewGoal(); return;
            case GoalsAddAction.UpdateAddOn: _ = UpdateGoalsAddOnAsync(store); return;
        }
        _ = NewTodoDialog.PresentAsync(XamlRoot, store, _view.ListId, _view == TodoView.Today ? DateTimeOffset.Now : null, made =>
        {
            if (made?.Helper is { } helper && PageKit.Bots.FirstOrDefault(b => b.Name == helper) is { } bot) Navigator.Go(new BotChatDestination(bot));
        });
    }
}
