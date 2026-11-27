using Hermes.Core.Kanban;
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
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Kanban;

/// Kanban on the Mac is a real board (App/Pages/Kanban/KanbanBoardView.swift, KanbanViewController.swift): "Kanban"
/// with the board's pop-up beside it, How Kanban Works, + and Search at the bar's end; one column per status across the
/// window, each task a card; a card dragged onto another column moves the task there (never into Scheduled, Running or
/// Review, which say why on their lock). A click opens the task in a panel at the right (KanbanTaskPanel); a
/// right-click is the card's menu. The board is read every 30 s while it shows.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class KanbanPage : Page
{
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    private KanbanStore? _store;
    private readonly TextBlock _title = new() { Text = KanbanCopy.Title, VerticalAlignment = VerticalAlignment.Center };
    private readonly DropDownButton _boardButton = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _about = new() { Content = new FontIcon { Glyph = "", FontSize = Hermes.Core.Shell.DesktopLook.BarGlyph } };
    private readonly Button _add = new() { Content = new FontIcon { Glyph = "", FontSize = Hermes.Core.Shell.DesktopLook.BarGlyph } };
    private readonly TextBox _search = new() { PlaceholderText = KanbanCopy.SearchPlaceholder, Width = 220, VerticalAlignment = VerticalAlignment.Center };
    // [WIN-KANBAN-COLUMNS] The columns' side, gap, top and foot are KanbanBoardGeometry's (the Mac's KanbanBoardView):
    // the side is the page bar's (DesktopLook.PageSide), so the first column stands under "Kanban". The board was 16 in,
    // 4 left of the title, and kept a column 120 tall in a shorter window, past the window's foot.
    private readonly StackPanel _columns = new()
    {
        Orientation = Orientation.Horizontal, Spacing = KanbanBoardGeometry.Gap,
        Padding = new Thickness(KanbanBoardGeometry.Side, KanbanBoardGeometry.Top, KanbanBoardGeometry.Side, KanbanBoardGeometry.Side),
    };
    private readonly ScrollViewer _boardScroll;
    private readonly Grid _state = new() { Visibility = Visibility.Collapsed };
    private readonly ContentControl _panelHost = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly Border _panel;
    private readonly NoticeLine _notice = new();
    private KanbanTaskPanel? _taskPanel;
    private string _query = "";
    private string? _selected;
    private bool _retrying;
    private string? _dragging;
    // More than eight boards: the board button pushes this "Boards" list over the page (KanbanBoardListController).
    private readonly Grid _boardsPage = new() { Visibility = Visibility.Collapsed };
    private readonly Grid _pageRoot;
    private KanbanBoardList? _boardList;

    public KanbanPage()
    {
        AutomationProperties.SetName(this, KanbanCopy.Title);
        _about.Style = Style("QuietButtonStyle");
        _add.Style = Style("QuietButtonStyle");
        AutomationProperties.SetName(_about, KanbanCopy.HowKanbanWorks);
        AutomationProperties.SetName(_add, KanbanCopy.NewTask);
        AutomationProperties.SetAutomationId(_add, "kanban.new");
        AutomationProperties.SetAutomationId(_about, "kanban.about");
        AutomationProperties.SetAutomationId(_search, "kanban.search");   // [WIN-50] the magnifier's field, at the bar's edge
        ToolTipService.SetToolTip(_about, KanbanCopy.HowKanbanWorks);
        ToolTipService.SetToolTip(_add, KanbanCopy.NewTask);
        _about.Click += (_, _) => _ = KanbanDialogs.ShowAboutAsync(XamlRoot);
        _add.Click += (_, _) => NewTask();
        _search.TextChanged += (_, _) => { _query = _search.Text; Render(); };
        // [WIN-KANBAN-SEARCH-STATE] The bar waits while the field is edited; leaving it settles the bar alone (a Render
        // here would rebuild the empty state's New Task… while that very click is landing).
        _search.LostFocus += (_, _) => ReconcileBar();
        AutomationProperties.SetName(_search, KanbanCopy.SearchPlaceholder);
        AutomationProperties.SetAutomationId(_boardButton, "kanban.board");
        // Up to eight boards the button's flyout is the menu; beyond, a click pushes the Boards list.
        _boardButton.Click += (_, _) => { if (_store?.BoardPickerStyle == KanbanBoardPickerStyle.List) ShowBoardList(); };

        // [WIN-50] The Mac's page bar (MacWindow.pageBar, Shell/PageBar.cs): the page-title token and the page's side;
        // How Kanban Works · New Task · Search at the edge (KanbanViewController.swift, DesktopBars.searchToEdge).
        HermesHQ.Shell.PageBar.Title(_title, "kanban");
        var bar = new Grid { Padding = HermesHQ.Shell.PageBar.Padding(12, 8), ColumnSpacing = 10 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(_title);
        Grid.SetColumn(_boardButton, 1);
        bar.Children.Add(_boardButton);
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        tools.Children.Add(_about);
        tools.Children.Add(_add);
        tools.Children.Add(_search);
        Grid.SetColumn(tools, 3);
        bar.Children.Add(tools);

        _boardScroll = new ScrollViewer
        {
            Content = _columns, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        _boardScroll.SizeChanged += (_, _) => SizeColumns();
        _panel = new Border
        {
            Width = 420, Visibility = Visibility.Collapsed, Child = _panelHost, BorderThickness = new Thickness(1, 0, 0, 0),
            BorderBrush = Brush("DividerStrokeColorDefaultBrush"), Background = Brush("LayerFillColorDefaultBrush"),
        };

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body.Children.Add(_boardScroll);
        body.Children.Add(_state);
        Grid.SetColumn(_panel, 1);
        body.Children.Add(_panel);

        var root = _pageRoot = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(bar);
        Grid.SetRow(body, 1);
        root.Children.Add(body);
        Grid.SetRow(_notice.Bar, 1);
        root.Children.Add(_notice.Bar);
        var page = new Grid();
        page.Children.Add(root);
        page.Children.Add(_boardsPage);
        Content = page;

        // F5 and Ctrl+R read the board again (the Mac's ⌘R); Ctrl+N is New Task here; Ctrl+F searches.
        Accelerator(VirtualKey.F5, VirtualKeyModifiers.None, () => _ = RefreshAsync());
        Accelerator(VirtualKey.R, VirtualKeyModifiers.Control, () => _ = RefreshAsync());
        Accelerator(VirtualKey.F, VirtualKeyModifiers.Control, () => _search.Focus(FocusState.Keyboard));
        Accelerator(VirtualKey.Escape, VirtualKeyModifiers.None, () => { if (_boardList != null) CloseBoardList(); else CloseTask(); });
        Accelerator(VirtualKey.Left, VirtualKeyModifiers.Menu, () => { if (_boardList != null) CloseBoardList(); });
    }

    private void Accelerator(VirtualKey key, VirtualKeyModifiers mods, Action run)
    {
        var a = new KeyboardAccelerator { Key = key, Modifiers = mods };
        a.Invoked += (_, e) => { e.Handled = true; run(); };
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        KeyboardAccelerators.Add(a);
        _accelerators[(key, mods)] = run;
    }

    private readonly Dictionary<(VirtualKey, VirtualKeyModifiers), Action> _accelerators = [];

    /// The CI walk's key press (KanbanWalks): runs what this page's own KeyboardAccelerator for the key runs, inside the
    /// app, with no key sent through the OS. False when the page has no accelerator for it.
    internal bool PressForWalk(VirtualKey key, VirtualKeyModifiers mods = VirtualKeyModifiers.None)
    {
        if (!KeyboardAccelerators.Any(a => a.Key == key && a.Modifiers == mods) || !_accelerators.TryGetValue((key, mods), out var run)) return false;
        run();
        return true;
    }

    private void OnStoreNotice(string text) => _ui.TryEnqueue(() => { if (!AppShutdown.Stopping) _notice.Show(text); });

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (AppState.Client is not { } client) return;
        _store = new KanbanStore(new KanbanApi(new GatewaySessionRest(client.Session)), client.AccountId, new FileKanbanPrefs());
        _store.Changed += OnChanged;
        _store.WriteFailed += OnStoreNotice;
        _store.Notice += OnStoreNotice;
        _store.SetVisible(true);
        AppLog.Note("kanban", "board shown");
        Render();
        if (e.Parameter is PlaceArgs { Argument: string taskId }) OpenTask(taskId);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _taskPanel?.Stop();
        CloseBoardList();
        if (_store != null)
        {
            _store.SetVisible(false);
            _store.Changed -= OnChanged;
            _store.WriteFailed -= OnStoreNotice;
            _store.Notice -= OnStoreNotice;
        }
    }

    private void OnChanged() => _ui.TryEnqueue(Render);

    private async Task RefreshAsync()
    {
        if (_store == null) return;
        if (await _store.RefreshAsync() != null) _notice.Show(KanbanCopy.CouldNotRefresh);
        _taskPanel?.Reload();
    }

    // ------------------------------------------------------------------ drawing

    private void Render()
    {
        if (_store is not { } store) return;
        RenderBoardButton(store);
        // [WIN-KANBAN-SEARCH-STATE] One decision for the state and the bar (KanbanSearchState, the Mac's
        // searchShownWhileEmpty): the trimmed words, the bar set on every path (loading and can't load too).
        var view = KanbanSearchState.Decide(store.Board, _query, SearchEditing, CurrentBar);
        ApplyBar(view.Bar);
        _columns.Children.Clear();
        _state.Children.Clear();
        if (view.Face == KanbanBoardFace.Status || store.Board is not { } board)
        {
            ShowState(store.BoardError is { } error ? ErrorState(error) : LoadingState());
            return;
        }
        if (view.Face != KanbanBoardFace.Columns)
        {
            // While the empty board offers New Task…, + leaves the bar, and Search with it (nothing to search); a search
            // with no match keeps both, so it can be cleared.
            ShowState(view.Face == KanbanBoardFace.NoResults
                ? EmptyState(KanbanCopy.NoResults(view.Words), KanbanCopy.TryAnotherWord, newTask: view.OffersNewTask)
                : EmptyState(KanbanCopy.NoTasksYet, KanbanCopy.NoTasksYetHelp, newTask: view.OffersNewTask));
            return;
        }
        var shown = KanbanModel.Filter(board, _query);
        _state.Visibility = Visibility.Collapsed;
        _boardScroll.Visibility = Visibility.Visible;
        var now = DateTimeOffset.Now;
        foreach (var status in KanbanModel.ChipOrder(shown.Columns.Select(c => c.Name)))
        {
            var column = shown.Columns.First(c => c.Name == status);
            _columns.Children.Add(ColumnView(status, column.Tasks, store, now));
        }
        SizeColumns();
    }

    /// The search field is open while it holds the keyboard (the Mac's unfolded field, `isSearchShown`).
    private bool SearchEditing => _search.FocusState != FocusState.Unfocused;

    private KanbanBoardBar CurrentBar => new(_search.Visibility == Visibility.Visible, _add.Visibility == Visibility.Visible);

    private void ApplyBar(KanbanBoardBar bar)
    {
        _search.Visibility = bar.SearchShown ? Visibility.Visible : Visibility.Collapsed;
        _add.Visibility = bar.AddShown ? Visibility.Visible : Visibility.Collapsed;
    }

    /// The field let go of the keyboard: the bar takes what the board now calls for, the state is left as drawn.
    private void ReconcileBar()
    {
        if (_store is not { } store) return;
        ApplyBar(KanbanSearchState.Decide(store.Board, _query, SearchEditing, CurrentBar).Bar);
    }

    private void ShowState(UIElement content)
    {
        _boardScroll.Visibility = Visibility.Collapsed;
        _state.Visibility = Visibility.Visible;
        _state.Children.Add(content);
    }

    /// Every column shares the room; at its narrowest (212) the board scrolls sideways instead, the side after the last
    /// column so it scrolls fully into view (KanbanBoardGeometry, one calculation with its tests). The scroller is the
    /// board's viewport: it narrows when the task panel opens beside it, and its SizeChanged sizes the columns again.
    /// Each column keeps its own vertical scroller; FlowDirection mirrors the row for right to left.
    private void SizeColumns()
    {
        var layout = KanbanBoardGeometry.Fit(_boardScroll.ActualWidth, _boardScroll.ActualHeight, _columns.Children.Count);
        if (layout.Count == 0) return;
        foreach (var child in _columns.Children.OfType<FrameworkElement>()) { child.Width = layout.ColumnWidth; child.Height = layout.ColumnHeight; }
    }

    private void RenderBoardButton(KanbanStore store)
    {
        _boardButton.Content = store.BoardTitle;
        _boardButton.IsEnabled = store.Boards != null;
        AutomationProperties.SetName(_boardButton, $"Board: {store.BoardTitle}. Switch board");
        if (store.BoardPickerStyle == KanbanBoardPickerStyle.List)
        {
            _boardButton.Flyout = null;   // the click pushes the Boards list
            return;
        }
        var menu = new MenuFlyout();
        foreach (var choice in store.BoardChoices)
        {
            // A ✓ on the open board, as the Mac's UIMenu(options: .singleSelection) draws for `state: .on` (a radio item
            // would draw a bullet). One tick at a time: a click leaves only the clicked item ticked.
            var item = new ToggleMenuFlyoutItem { Text = choice.MenuText, IsChecked = choice.IsCurrent };
            AutomationProperties.SetAutomationId(item, "kanban.boards.menu." + choice.Slug);
            var slug = choice.Slug;
            item.Click += (_, _) =>
            {
                foreach (var other in menu.Items.OfType<ToggleMenuFlyoutItem>()) other.IsChecked = ReferenceEquals(other, item);
                PickBoard(slug);
            };
            menu.Items.Add(item);
        }
        _boardButton.Flyout = menu;
    }

    /// `pickBoard`: the open board does nothing; another clears the search, closes the task and reads the new board.
    private void PickBoard(string slug)
    {
        if (_store is not { } store || !KanbanBoardPicker.Switches(slug, store.BoardKey)) return;
        _search.Text = "";
        _query = "";
        CloseTask();
        store.Select(slug);
    }

    // ------------------------------------------------------------------ the Boards list (more than eight boards)

    /// The pushed list: Back (to Kanban), "Boards", a search field over twelve boards, a row per board with its task
    /// count and a tick on the open one. A pick switches the board and goes back; Back, Esc or Alt+Left go back as is.
    /// UI Automation sees the transition by id: with 8 boards `kanban.board` expands a menu of `kanban.boards.menu.<slug>`
    /// items and no `kanban.boards` page appears; with 9 it invokes into `kanban.boards` (rows `kanban.boards.row.<slug>`,
    /// `kanban.boards.back`), with `kanban.boards.search` only from 13.
    private void ShowBoardList()
    {
        if (_store is not { } store || store.Boards is not { } boards) return;
        var list = _boardList = new KanbanBoardList(boards.Boards, store.BoardKey);
        _boardsPage.Children.Clear();
        _boardsPage.RowDefinitions.Clear();
        _boardsPage.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _boardsPage.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _boardsPage.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        AutomationProperties.SetAutomationId(_boardsPage, "kanban.boards");
        AutomationProperties.SetName(_boardsPage, list.Title);

        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(8, 12, 12, 8) };
        var back = new Button { Content = new FontIcon { Glyph = "\uE72B", FontSize = 14 }, Style = Style("QuietButtonStyle"), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(back, "Back to " + KanbanCopy.Title);
        AutomationProperties.SetAutomationId(back, "kanban.boards.back");
        ToolTipService.SetToolTip(back, KanbanCopy.Title);
        back.Click += (_, _) => CloseBoardList();
        bar.Children.Add(back);
        var title = Text(list.Title, 20, bold: true, wrap: false);
        title.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        bar.Children.Add(title);
        _boardsPage.Children.Add(bar);

        var rows = new StackPanel { Spacing = 0 };
        var card = new Border
        {
            Child = rows, CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1),
            Background = Brush("CardBackgroundFillColorDefaultBrush"), BorderBrush = Brush("CardStrokeColorDefaultBrush"),
            HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(16, 4, 16, 16),
        };
        AutomationProperties.SetAutomationId(rows, "kanban.boards.list");
        void Fill()
        {
            rows.Children.Clear();
            foreach (var choice in list.Shown) rows.Children.Add(BoardRow(choice));
        }
        if (list.HasSearch)
        {
            var search = new TextBox { PlaceholderText = "Search", Margin = new Thickness(16, 0, 16, 8), HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(search, "Search Boards");
            AutomationProperties.SetAutomationId(search, "kanban.boards.search");
            search.TextChanged += (_, _) => { list.Search(search.Text); Fill(); };
            Grid.SetRow(search, 1);
            _boardsPage.Children.Add(search);
        }
        Fill();
        // The list and its search span the page, as the Mac's inset grouped list does. A 640 cap with Stretch came out
        // right of centre inside this ScrollViewer, its ticks off the window (CI 44971143103, 44971835430).
        var scroll = new ScrollViewer
        {
            Content = card, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Disabled,
        };
        Grid.SetRow(scroll, 2);
        _boardsPage.Children.Add(scroll);

        _pageRoot.Visibility = Visibility.Collapsed;
        _boardsPage.Visibility = Visibility.Visible;
        back.Focus(FocusState.Programmatic);
    }

    private FrameworkElement BoardRow(KanbanBoardChoice choice)
    {
        var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(14, 9, 14, 9) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(Text(choice.Title, 14));
        if (choice.Subtitle is { } sub) words.Children.Add(Text(sub, 12, color: Secondary));
        grid.Children.Add(words);
        if (choice.IsCurrent)
        {
            var tick = new FontIcon { Glyph = "\uE73E", FontSize = 14, Foreground = Accent, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(tick, 1);
            grid.Children.Add(tick);
        }
        var row = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Solid(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(0),
        };
        AutomationProperties.SetName(row, choice.Subtitle is { } s ? $"{choice.Title}, {s}" : choice.Title);
        AutomationProperties.SetAutomationId(row, "kanban.boards.row." + choice.Slug);
        if (choice.IsCurrent) AutomationProperties.SetItemStatus(row, "Selected");
        var slug = choice.Slug;
        row.Click += (_, _) => { PickBoard(slug); CloseBoardList(); };
        return row;
    }

    private void CloseBoardList()
    {
        if (_boardList == null) return;
        _boardList = null;
        _boardsPage.Visibility = Visibility.Collapsed;
        _boardsPage.Children.Clear();
        _pageRoot.Visibility = Visibility.Visible;
        _boardButton.Focus(FocusState.Programmatic);
    }

    private FrameworkElement ColumnView(string status, IReadOnlyList<KanbanTask> tasks, KanbanStore store, DateTimeOffset now)
    {
        var header = new Grid { ColumnSpacing = 7, Padding = new Thickness(12, 10, 12, 8) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Dot(Tone(status)));
        var name = Text(KanbanModel.Label(status), 14, bold: true, wrap: false);
        Grid.SetColumn(name, 1);
        header.Children.Add(name);
        if (KanbanModel.IsLocked(status))
        {
            var lockIcon = new FontIcon { Glyph = "", FontSize = 10, Foreground = Tertiary };
            AutomationProperties.SetName(lockIcon, KanbanModel.LockedReason(status));
            Grid.SetColumn(lockIcon, 2);
            header.Children.Add(lockIcon);
            ToolTipService.SetToolTip(header, KanbanModel.LockedReason(status));
        }
        var count = Text(tasks.Count.ToString(), 13, color: Secondary);
        Grid.SetColumn(count, 4);
        header.Children.Add(count);

        var cards = new StackPanel { Spacing = 8, Padding = new Thickness(8, 2, 8, 10) };
        foreach (var task in tasks) cards.Children.Add(CardView(task, store, now));
        if (tasks.Count == 0)
            cards.Children.Add(new TextBlock { Text = KanbanCopy.NoTasks, FontSize = 12, Foreground = Tertiary, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 0) });

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(header);
        var scroll = new ScrollViewer { Content = cards, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 1);
        grid.Children.Add(scroll);
        var panel = new Border
        {
            Child = grid, CornerRadius = new CornerRadius(12), Background = Brush("SubtleFillColorSecondaryBrush"),
            BorderThickness = new Thickness(2), BorderBrush = Solid(Microsoft.UI.Colors.Transparent), AllowDrop = true,
        };
        AutomationProperties.SetName(panel, $"{KanbanModel.Label(status)}, {tasks.Count} {(tasks.Count == 1 ? "task" : "tasks")}");
        AutomationProperties.SetAutomationId(panel, "kanban.column." + status);

        // A card held over a column a person may move it to lights its edge; the statuses the board sets take none.
        bool Takes() => _dragging is { } id && !KanbanModel.IsLocked(status) && status != "archived" && store.Board?.Task(id)?.Status is { } from && from != status;
        panel.DragOver += (_, e) =>
        {
            var ok = Takes();
            e.AcceptedOperation = ok ? DataPackageOperation.Move : DataPackageOperation.None;
            panel.BorderBrush = ok ? Accent : Solid(Microsoft.UI.Colors.Transparent);
        };
        panel.DragLeave += (_, _) => panel.BorderBrush = Solid(Microsoft.UI.Colors.Transparent);
        panel.Drop += (_, _) =>
        {
            panel.BorderBrush = Solid(Microsoft.UI.Colors.Transparent);
            if (!Takes() || store.Board?.Task(_dragging!) is not { } task) return;
            _dragging = null;
            _ = store.MoveAsync(task, status);
        };
        return panel;
    }

    private FrameworkElement CardView(KanbanTask task, KanbanStore store, DateTimeOffset now)
    {
        var model = KanbanCardModel.For(task, store.Fallback, BotName, now);
        var title = Text(task.Title.Length == 0 ? task.Id : task.Title, 13, bold: true);
        title.MaxLines = 4;
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        var meta = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Secondary };
        for (var i = 0; i < model.Bits.Count; i++)
        {
            var bit = model.Bits[i];
            meta.Inlines.Add(new Run
            {
                Text = bit.Text, FontWeight = bit.Alert ? FontWeights.SemiBold : FontWeights.Normal,
                Foreground = bit.Alert ? Critical : Secondary,
            });
            // A no-break space keeps the dot with the bit before it.
            if (i < model.Bits.Count - 1) meta.Inlines.Add(new Run { Text = " · " });
        }
        var line = new Grid { ColumnSpacing = 6 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.Children.Add(Face(model.Assignee, 18));
        Grid.SetColumn(meta, 1);
        line.Children.Add(meta);
        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(title);
        stack.Children.Add(line);
        var chosen = _selected == task.Id;
        var card = new Border
        {
            Child = stack, Padding = new Thickness(10, 9, 10, 9), CornerRadius = new CornerRadius(9), BorderThickness = new Thickness(1),
            Background = chosen ? AccentWash(0.14) : Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = chosen ? AccentWash(0.6) : Brush("CardStrokeColorDefaultBrush"), CanDrag = true,
        };
        AutomationProperties.SetName(card, model.Spoken);
        AutomationProperties.SetAutomationId(card, "kanban-task-" + task.Id);
        card.PointerEntered += (_, _) => { if (_selected != task.Id) card.Background = Brush("CardBackgroundFillColorSecondaryBrush"); };
        card.PointerExited += (_, _) => { if (_selected != task.Id) card.Background = Brush("CardBackgroundFillColorDefaultBrush"); };
        card.Tapped += (_, _) => OpenTask(task.Id);
        card.DragStarting += (_, e) =>
        {
            _dragging = task.Id;
            e.Data.SetText(task.Title.Length == 0 ? task.Id : task.Title);
            e.Data.RequestedOperation = DataPackageOperation.Move;
        };
        card.DropCompleted += (_, _) => _dragging = null;
        card.ContextFlyout = CardMenu(task, store);
        return card;
    }

    // ------------------------------------------------------------------ the card's menu

    private MenuFlyout CardMenu(KanbanTask task, KanbanStore store)
    {
        var menu = new MenuFlyout();
        // A card's right-click menu starts with what a click does.
        menu.Items.Add(Item(KanbanCopy.OpenTask, "", () => OpenTask(task.Id)));
        menu.Items.Add(new MenuFlyoutSeparator());
        if (KanbanModel.QuickMove(task.Status) is { } quick && !KanbanModel.IsLocked(quick.To))
        {
            var glyph = quick.Label == "Unblock" ? "" : quick.Label == "Reopen" ? "" : "";
            menu.Items.Add(Item(quick.Label, glyph, () => _ = store.MoveAsync(task, quick.To)));
        }
        var move = new MenuFlyoutSubItem { Text = KanbanCopy.MoveTo, Icon = new FontIcon { Glyph = "" } };
        foreach (var name in (store.Board?.Columns.Select(c => c.Name) ?? []).Where(n => n != task.Status && n != "archived" && !KanbanModel.IsLocked(n)))
        {
            var to = name;
            move.Items.Add(Item(KanbanModel.Label(to), null, () => _ = store.MoveAsync(task, to)));
        }
        menu.Items.Add(move);
        var assign = new MenuFlyoutSubItem { Text = KanbanCopy.AssignTo, Icon = new FontIcon { Glyph = "" } };
        foreach (var profile in store.Profiles)
        {
            var name = profile.Name;
            assign.Items.Add(new ToggleMenuFlyoutItem { Text = BotName(name), IsChecked = name == task.Assignee, Command = new Do(() => _ = store.AssignAsync(task, name)) });
        }
        // Last, as New Task lists No One Yet: unassigned (the board's default bot, if any, then runs it).
        assign.Items.Add(new MenuFlyoutSeparator());
        assign.Items.Add(new ToggleMenuFlyoutItem
        {
            Text = KanbanModel.NobodyWords(store.Fallback.Length == 0 ? "" : BotName(store.Fallback)), IsChecked = task.Assignee == null,
            Command = new Do(() => _ = store.AssignAsync(task, "")),
        });
        menu.Items.Add(assign);
        menu.Items.Add(new MenuFlyoutSeparator());
        if (task.Status == "done") menu.Items.Add(Item(KanbanCopy.Archive, "", () => _ = ArchiveAsync(task)));
        var delete = Item(KanbanCopy.DeleteTaskEllipsis, "", () => _ = ConfirmDeleteAsync(task));
        delete.Foreground = Critical;
        menu.Items.Add(delete);
        return menu;
    }

    private static MenuFlyoutItem Item(string text, string? glyph, Action run)
    {
        var item = new MenuFlyoutItem { Text = text };
        if (glyph != null) item.Icon = new FontIcon { Glyph = glyph };
        item.Click += (_, _) => run();
        return item;
    }

    /// Archive: the card leaves at once; "Archived" with Undo (KanbanFeedback.archived).
    internal async Task ArchiveAsync(KanbanTask task)
    {
        if (_store is not { } store) return;
        var from = task.Status;
        if (await store.ArchiveAsync(task, reason => _ = FailedAsync(XamlRoot, KanbanWriteWords.FailureTitle("archive")!, reason, () => ArchiveAsync(task))) is not { } board) return;
        if (_selected == task.Id) CloseTask();
        _notice.Show(KanbanCopy.ArchivedDetail, 6, KanbanCopy.Archived, KanbanCopy.Undo, () => _ = UndoArchiveAsync(task, from, board));
    }

    private async Task UndoArchiveAsync(KanbanTask task, string status, string board)
    {
        if (_store is not { } store) return;
        if (await store.UnarchiveAsync(task, status, board) is { } reason)
            await FailedAsync(XamlRoot, KanbanWriteWords.FailureTitle(KanbanWriteWords.UndoArchive)!, reason, () => UndoArchiveAsync(task, status, board));
    }

    internal async Task ConfirmDeleteAsync(KanbanTask task)
    {
        if (_store is not { } store) return;
        if (store.ReadOnlyGateway) { _notice.Show(KanbanRest.ReadOnlyNotice); return; }
        if (!await ConfirmAsync(XamlRoot, KanbanCopy.DeleteThisTask, KanbanCopy.DeleteMessage(task.Title), KanbanCopy.DeleteTask)) return;
        if (_selected == task.Id) CloseTask();
        await store.DeleteAsync(task, reason => _ = FailedAsync(XamlRoot, KanbanWriteWords.FailureTitle("delete")!, reason, () => store.DeleteAsync(task)));
    }

    // ------------------------------------------------------------------ the task panel

    internal void OpenTask(string id)
    {
        if (_store == null) return;
        _selected = id;
        _taskPanel?.Stop();
        _taskPanel = new KanbanTaskPanel(_store, id, this);
        _panelHost.Content = _taskPanel;
        _panel.Visibility = Visibility.Visible;
        _taskPanel.Start();
        Render();
    }

    internal void CloseTask()
    {
        if (_taskPanel == null) return;
        _taskPanel.Stop();
        _taskPanel = null;
        _panelHost.Content = null;
        _panel.Visibility = Visibility.Collapsed;
        _selected = null;
        Render();
    }

    internal void ShowNotice(string text) => _notice.Show(text);

    private void NewTask()
    {
        if (_store is not { } store) return;
        if (store.ReadOnlyGateway) { _notice.Show(KanbanRest.ReadOnlyNotice); return; }
        _ = KanbanDialogs.NewTaskAsync(XamlRoot, store, warning => { if (warning != null) _notice.Show(warning, 5); });
    }

    // ------------------------------------------------------------------ states

    private UIElement LoadingState()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 40, 0, 0), VerticalAlignment = VerticalAlignment.Top };
        row.Children.Add(new ProgressRing { IsActive = true, Width = 18, Height = 18 });
        row.Children.Add(Text(KanbanCopy.Loading, 14, color: Secondary));
        return row;
    }

    private UIElement ErrorState(string error)
    {
        var stack = new StackPanel { Spacing = 4 };
        stack.Children.Add(Text(KanbanCopy.CouldNotLoadBoard, 14));
        stack.Children.Add(Text(error, 12, color: Secondary));
        var retry = Push(_retrying ? KanbanCopy.Trying : KanbanCopy.TryAgain, () => _ = RetryAsync());
        retry.IsEnabled = !_retrying;
        retry.Margin = new Thickness(0, 8, 0, 0);
        stack.Children.Add(retry);
        var card = Card(stack, 16);
        card.MaxWidth = 480;
        card.Margin = new Thickness(20, 20, 20, 20);
        card.VerticalAlignment = VerticalAlignment.Top;
        return card;
    }

    private async Task RetryAsync()
    {
        if (_store == null) return;
        _retrying = true;
        Render();
        await _store.ReadBoardAsync();
        _retrying = false;
        Render();
    }

    private UIElement EmptyState(string title, string help, bool newTask)
    {
        var stack = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(24, 60, 24, 40), MaxWidth = 420 };
        stack.Children.Add(new FontIcon { Glyph = "", FontSize = 34, Foreground = Tertiary, Margin = new Thickness(0, 0, 0, 4) });
        var t = Text(title, 18, bold: true);
        t.TextAlignment = TextAlignment.Center;
        stack.Children.Add(t);
        var h = Text(help, 13, color: Secondary);
        h.TextAlignment = TextAlignment.Center;
        stack.Children.Add(h);
        if (newTask)
        {
            var b = Push(KanbanCopy.NewTaskEllipsis, NewTask);
            b.HorizontalAlignment = HorizontalAlignment.Center;
            b.Margin = new Thickness(0, 8, 0, 0);
            AutomationProperties.SetAutomationId(b, "kanban.empty.new");
            stack.Children.Add(b);
        }
        return stack;
    }
}

/// A menu item's command.
internal sealed class Do(Action run) : System.Windows.Input.ICommand
{
#pragma warning disable CS0067
    public event EventHandler? CanExecuteChanged;
#pragma warning restore CS0067
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => run();
}
