using Hermes.Core;
using Hermes.Core.Insights;
using Hermes.Core.Jobs;
using Hermes.Core.Kanban;
using Hermes.Core.Net;
using Hermes.Core.QuickActions;
using Hermes.Core.Workspace;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Composer;
using HermesHQ.Features.Insights;
using HermesHQ.Features.Jobs;
using HermesHQ.Features.Kanban;
using HermesHQ.Features.OpenQuickly;
using HermesHQ.Features.Transcript;
using HermesHQ.Features.Voice;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.System;
using Windows.UI;

namespace HermesHQ.Features.QuickActions;

/// The expanded Favorites page (`App/QuickActions/QuickActionsViewController.swift`): full-width responsive 2–5 column
/// 2D Bento canvas, 28 tile kinds (actions, 10 native live cards, Dashboard tiles, deeper shortcuts, sequential
/// routines, collapsible sections), 7 tile sizes, multi-page spaces (`FavoritePagesBar`), 4 starter presets, inline
/// Quick Ask, gateway sync (`ui_meta["hermes-hq-sync.favorites"]`), and Ctrl+1..9 / Ctrl+F / Ctrl+N / Ctrl+R shortcuts.
/// When presented via `ShowSheetAsync`, retains the compact modal sheet proportions (478 × 441 DIP).
/// [WIN-QUICK-GRID] At accessibility text sizes (`QuickTileLayout.StackedAt`), collapses cleanly to 1 full-width column
/// laid out by `QuickTileLayout.Fit`, keeping focus stable across redraws.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class QuickActionsPage : Page, IKeyRefreshing
{
    public const double SheetWidth = 496;
    public const double SheetMinHeight = 441;

    private QuickTileList _list = new();
    private string _currentPage = FavoritePage.MainId;
    private string _searchQuery = "";
    private bool _hideOtherGateways;
    private bool _editing, _seeding;
    private readonly bool _inSheet;
    private readonly Action? _dismissSheet;
    private readonly StackPanel _grid = new();
    private readonly ScrollViewer _scroll = new() { HorizontalScrollMode = ScrollMode.Disabled };
    private readonly Grid _overlay;
    private readonly FavoritePagesBar _pagesBar = new();
    private readonly TextBox _searchBox;
    private readonly Button _addToolbarBtn;
    private readonly Button _moreToolbarBtn;
    private readonly Button _edit = new() { Content = "Edit" };
    private readonly NoticeLine _notice = new();
    private readonly FavoritesLiveModel _live = new();
    private readonly FavoriteTiles _dashboardTiles = new();
    private TileViewer? _viewer;
    private FavoritesSync? _sync;
    private string? _syncAccountId;
    private Action? _syncHook;
    /// Kept for its TextScaleFactorChanged (a UISettings let go of stops raising it).
    private readonly Windows.UI.ViewManagement.UISettings _ui = new();
    private (bool Stacked, double Side, double Gap)? _drawnKey;
    private (bool Stacked, double Side, double Gap, int Columns, int WidthBucket)? _drawnBentoKey;
    /// The tile a menu's Move Up / Down or Small / Wide acted on: the keyboard goes back to it once redrawn.
    private string? _focusAfter;
    private CancellationTokenSource? _seedWait;
    private ListsHub? _hub;

    public QuickActionsPage() : this(inSheet: false, dismiss: null) { }

    internal QuickActionsPage(bool inSheet, Action? dismiss)
    {
        _inSheet = inSheet;
        _dismissSheet = dismiss;
        var pageTitle = Places.Get(QuickActionsFeature.PlaceId).Title;
        AutomationProperties.SetName(this, pageTitle);
        AutomationProperties.SetAutomationId(this, "quick-actions.page");
        AutomationProperties.SetAutomationId(_edit, "quick-actions.edit");
        _edit.Click += (_, _) => SetEditing(!_editing);

        _searchBox = new TextBox
        {
            PlaceholderText = "Search Favorites…",
            Width = 200,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_searchBox, "favorites.search");
        AutomationProperties.SetName(_searchBox, "Search Favorites");
        _searchBox.TextChanged += (_, _) => { _searchQuery = _searchBox.Text.Trim(); Draw(); };
        _searchBox.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Escape)
            {
                e.Handled = true;
                _searchBox.Text = "";
                _searchQuery = "";
                _searchBox.Visibility = Visibility.Collapsed;
                Draw();
            }
        };

        _addToolbarBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE710", FontSize = 14 },
            Padding = new Thickness(8, 6, 8, 6),
        };
        ToolTipService.SetToolTip(_addToolbarBtn, "Add Action (Ctrl+N)");
        AutomationProperties.SetAutomationId(_addToolbarBtn, "favorites.toolbar.add");
        AutomationProperties.SetName(_addToolbarBtn, "Add Action");
        _addToolbarBtn.Click += (_, _) => _ = ShowAddAsync();

        _moreToolbarBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE712", FontSize = 14 },
            Padding = new Thickness(8, 6, 8, 6),
        };
        ToolTipService.SetToolTip(_moreToolbarBtn, "More Options");
        AutomationProperties.SetAutomationId(_moreToolbarBtn, "favorites.toolbar.more");
        AutomationProperties.SetName(_moreToolbarBtn, "More Options");
        _moreToolbarBtn.Click += (_, _) => _moreToolbarBtn.Flyout = BuildToolbarMenu();
        _moreToolbarBtn.Flyout = BuildToolbarMenu();

        var toolbarRight = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        toolbarRight.Children.Add(_searchBox);
        toolbarRight.Children.Add(_addToolbarBtn);
        toolbarRight.Children.Add(_moreToolbarBtn);
        toolbarRight.Children.Add(_edit);

        // [WIN-50] The Mac's page bar (MacWindow.pageBar, Shell/PageBar.cs): the page-title token and the page's side.
        var bar = new Grid { Padding = inSheet ? new Thickness(16, 12, 16, 6) : HermesHQ.Shell.PageBar.Padding(12, 4), ColumnSpacing = 10 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new TextBlock { Text = pageTitle, VerticalAlignment = VerticalAlignment.Center };
        HermesHQ.Shell.PageBar.Title(title, "quick-actions");
        bar.Children.Add(title);
        Grid.SetColumn(toolbarRight, 1);
        bar.Children.Add(toolbarRight);

        WirePagesBar();

        var scroll = _scroll;
        scroll.Content = _grid;
        AutomationProperties.SetAutomationId(scroll, "quick-actions.grid");
        scroll.SizeChanged += (_, _) =>
        {
            var k = Key();
            var bk = QuickTileLayout.BentoKey(_scroll.ActualWidth, TextScale());
            if (_drawnKey != k || _drawnBentoKey != bk) Draw();
        };

        var sheetBody = new Grid();
        sheetBody.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        sheetBody.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        sheetBody.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(_pagesBar, 1);
        Grid.SetRow(scroll, 2);
        Grid.SetRow(_notice.Bar, 2);
        sheetBody.Children.Add(bar);
        sheetBody.Children.Add(_pagesBar);
        sheetBody.Children.Add(scroll);
        sheetBody.Children.Add(_notice.Bar);

        _overlay = new Grid { Children = { sheetBody } };
        Content = _overlay;

        InstallShortcuts();
        _live.Changed += OnLiveChanged;
        _dashboardTiles.Changed += OnDashboardTilesChanged;
    }

    /// Presents Favorites in a centered modal sheet (matching Mac's 478 × 441 ⌘⇧K sheet).
    public static async Task ShowSheetAsync(XamlRoot? root)
    {
        if (root == null) return;
        ContentDialog? dialog = null;
        var page = new QuickActionsPage(inSheet: true, dismiss: () => dialog?.Hide())
        {
            Width = 478,
            MinHeight = SheetMinHeight,
            MaxHeight = 560,
        };
        dialog = new ContentDialog
        {
            XamlRoot = root,
            Content = page,
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(dialog, "quick-actions.sheet");
        page.ActivateSheet();
        try { await PageKit.ShowAsync(root, dialog); }
        finally { page.DeactivateSheet(); }
    }

    private void InstallShortcuts()
    {
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        void Bind(VirtualKey key, Action run)
        {
            var acc = new KeyboardAccelerator { Key = key, Modifiers = VirtualKeyModifiers.Control };
            acc.Invoked += (_, e) => { e.Handled = true; run(); };
            KeyboardAccelerators.Add(acc);
        }
        Bind(VirtualKey.N, () => _ = ShowAddAsync());
        Bind(VirtualKey.F, ToggleSearch);
        Bind(VirtualKey.R, KeyRefresh);
        for (var i = 0; i < 9; i++)
        {
            var index = i;
            Bind((VirtualKey)((int)VirtualKey.Number1 + i), () => HandleDigitShortcut(index));
        }
    }

    private void ToggleSearch()
    {
        if (_searchBox.Visibility == Visibility.Visible)
        {
            _searchBox.Text = "";
            _searchQuery = "";
            _searchBox.Visibility = Visibility.Collapsed;
            Draw();
        }
        else
        {
            _searchBox.Visibility = Visibility.Visible;
            _searchBox.Focus(FocusState.Programmatic);
        }
    }

    private void HandleDigitShortcut(int index)
    {
        if (_list.HasMultiplePages)
        {
            var pages = _list.AllPages;
            if (index >= 0 && index < pages.Count) SelectPage(pages[index].Id);
            return;
        }
        var tiles = CurrentVisibleTiles();
        if (index >= 0 && index < tiles.Count) _ = RunLoggedAsync(tiles[index]);
    }

    public void KeyRefresh()
    {
        var tiles = CurrentVisibleTiles();
        _dashboardTiles.EnsureLoaded(tiles, fresh: true);
        _ = _live.RefreshAllAsync(tiles);
        _ = SyncNowAsync();
        _notice.Show("Refreshed live cards", 2);
    }

    // ------------------------------------------------------------------ lifecycle & sync

    internal void ActivateSheet() => BeginActive("open sheet");
    internal void DeactivateSheet() => EndActive();

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        BeginActive("open");
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        EndActive();
    }

    private void BeginActive(string note)
    {
        if (_hub != null) _hub.Changed -= Reload;
        _hub = ListsHub.Current;
        if (_hub != null) _hub.Changed += Reload;
        _ui.TextScaleFactorChanged -= TextScaleChanged;
        _ui.TextScaleFactorChanged += TextScaleChanged;
        _dashboardTiles.Attach(AppState.Client);
        AttachSync();
        AppLog.Note("quick-actions", note);
        LoadList();
        _live.Start(_list.Tiles);
        _dashboardTiles.EnsureLoaded(CurrentVisibleTiles(), fresh: false);
        _ = SyncNowAsync();
    }

    private void EndActive()
    {
        if (_hub != null) { _hub.Changed -= Reload; _hub = null; }
        _ui.TextScaleFactorChanged -= TextScaleChanged;
        _seedWait?.Cancel();
        _live.Stop();
        _dashboardTiles.Detach();
        CloseViewer();
        DetachSync();
        _editing = false;
    }

    private void AttachSync()
    {
        var client = AppState.Client;
        var accountId = client?.AccountId;
        if (accountId == _syncAccountId && _sync != null) return;
        DetachSync();
        if (client == null || string.IsNullOrEmpty(accountId)) return;
        _syncAccountId = accountId;
        var statePath = TilePinStore.FileFor(System.IO.Path.Combine(AppPaths.Root, "favorites-sync"), accountId);
        var sync = new FavoritesSync(
            (m, p, t, ct) => AppState.Client is { } c
                ? c.Rpc.RequestAsync(m, p, t, ct)
                : throw new GatewayException("offline", "Not connected to the gateway."),
            QuickActionsFeature.Store,
            statePath);
        sync.Adopted += OnSyncAdopted;
        _sync = sync;
        _syncHook = () => _sync?.SchedulePush();
        QuickTileStore.OnLocalSave += _syncHook;
    }

    private void DetachSync()
    {
        if (_syncHook != null)
        {
            QuickTileStore.OnLocalSave -= _syncHook;
            _syncHook = null;
        }
        if (_sync != null)
        {
            _sync.Adopted -= OnSyncAdopted;
            _sync.Dispose();
            _sync = null;
        }
        _syncAccountId = null;
    }

    private void OnSyncAdopted()
    {
        if (AppShutdown.Stopping) return;
        DispatcherQueue?.TryEnqueue(() =>
        {
            if (AppShutdown.Stopping || !IsLoaded) return;
            Reload();
        });
    }

    private async Task SyncNowAsync()
    {
        var sync = _sync;
        if (sync == null) return;
        try { await sync.SyncAsync(); }
        catch (Exception e) when (e is GatewayException or OperationCanceledException) { }
    }

    private void OnLiveChanged()
    {
        if (AppShutdown.Stopping || !IsLoaded) return;
        Draw();
    }

    private void OnDashboardTilesChanged()
    {
        if (AppShutdown.Stopping) return;
        DispatcherQueue?.TryEnqueue(() =>
        {
            if (AppShutdown.Stopping || !IsLoaded) return;
            Draw();
        });
    }

    // ------------------------------------------------------------------ pages bar & toolbar menu

    private void WirePagesBar()
    {
        _pagesBar.PageSelected += SelectPage;
        _pagesBar.AddPageRequested += () => _ = AddPageAsync();
        _pagesBar.RenamePageRequested += page => _ = RenamePageAsync(page);
        _pagesBar.ChangeSymbolRequested += (page, sym) => Change(l => l.SetPageSymbol(page.Id, sym));
        _pagesBar.MovePageRequested += (page, delta) => Change(l => l.MovePage(page.Id, delta));
        _pagesBar.ReorderPageRequested += (src, dst) => Change(l => l.ReorderPage(src, dst));
        _pagesBar.DeletePageRequested += page => _ = DeletePageAsync(page);
    }

    private MenuFlyout BuildToolbarMenu()
    {
        var menu = new MenuFlyout();
        void AddItem(string text, string glyph, Action run)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            item.Click += (_, _) => run();
            menu.Items.Add(item);
        }
        AddItem("Add Section Header", "\uE8FD", () => _ = AddSectionHeaderAsync());
        AddItem("New Page…", "\uE8F4", () => _ = AddPageAsync());
        AddItem("Starter Presets…", "\uE734", () => _ = ShowPresetsAsync());
        menu.Items.Add(new MenuFlyoutSeparator());
        AddItem("Search Favorites (Ctrl+F)", "\uE721", ToggleSearch);
        var gwFilter = new ToggleMenuFlyoutItem
        {
            Text = "This Gateway Only",
            IsChecked = _hideOtherGateways,
            Icon = new FontIcon { Glyph = "\uE71C" },
        };
        gwFilter.Click += (_, _) =>
        {
            _hideOtherGateways = gwFilter.IsChecked;
            QuickTileStore.SetHidesOtherGateways(_hideOtherGateways, QuickActionsFeature.Store);
            Draw();
        };
        menu.Items.Add(gwFilter);
        AddItem("Refresh Live Cards (Ctrl+R)", "\uE72C", KeyRefresh);
        return menu;
    }

    private void SelectPage(string pageId)
    {
        var target = _list.AllPages.Any(p => p.Id == pageId) ? pageId : FavoritePage.MainId;
        if (_currentPage == target) return;
        _currentPage = target;
        QuickTileStore.SetCurrentPage(target, QuickActionsFeature.Store);
        _dashboardTiles.EnsureLoaded(CurrentVisibleTiles(), fresh: false);
        _live.UpdateTiles(_list.Tiles);
        Reload();
    }

    private async Task AddPageAsync()
    {
        var name = await PageKit.PromptAsync(XamlRoot, "New Page", "Give this Favorites page a name.", "", "Create", "Work");
        if (string.IsNullOrWhiteSpace(name)) return;
        FavoritePage? created = null;
        Change(l => created = l.AddPage(name));
        if (created != null)
        {
            SelectPage(created.Id);
            _notice.Show($"Created page {created.Name}", 2);
        }
    }

    private async Task RenamePageAsync(FavoritePage page)
    {
        var name = await PageKit.PromptAsync(XamlRoot, "Rename Page", "Choose a new name for this page.", page.Name, "Save", page.Name);
        if (string.IsNullOrWhiteSpace(name) || name.Trim() == page.Name) return;
        Change(l => l.RenamePage(page.Id, name));
    }

    private async Task DeletePageAsync(FavoritePage page)
    {
        if (page.Id == FavoritePage.MainId) return;
        var ok = await PageKit.ConfirmAsync(XamlRoot, $"Delete “{page.Name}”?",
            "Tiles on this page will move back to Home.", "Delete Page");
        if (!ok) return;
        Change(l => l.DeletePage(page.Id, deleteTiles: false));
        if (_currentPage == page.Id) SelectPage(FavoritePage.MainId);
        _notice.Show($"Deleted {page.Name}", 2);
    }

    private async Task AddSectionHeaderAsync()
    {
        var name = await PageKit.PromptAsync(XamlRoot, "Add Section Header", "Group tiles under a collapsible heading.", "", "Add", "Daily Ops");
        if (string.IsNullOrWhiteSpace(name)) return;
        var tile = QuickTile.Create(QuickTileKind.Section, name: name.Trim()) with
        {
            PageId = _currentPage == FavoritePage.MainId ? null : _currentPage,
        };
        Change(l => l.Add(tile));
        _notice.Show($"Added section {tile.Name}", 2);
    }

    private async Task ShowPresetsAsync()
    {
        var pageName = _list.AllPages.FirstOrDefault(p => p.Id == _currentPage)?.Name ?? "Home";
        var picked = await FavoritePresetsDialog.ShowAsync(XamlRoot, pageName);
        if (picked == null) return;
        var firstBot = ListsHub.Current?.Bots.Rows.FirstOrDefault() is { } b ? ((string, string)?)(b.Id, b.Model.DisplayName) : null;
        var firstGoal = _live.Tasks?.Goals.FirstOrDefault(g => g.State == Hermes.Core.Tasks.GoalState.Active) is { } g ? ((string, string)?)(g.Id, g.Shown) : null;
        var generated = picked.Preset.Tiles(firstBot, firstGoal, _currentPage);
        Change(l =>
        {
            if (picked.ReplaceCurrentPage) l.RemoveOnPage(_currentPage);
            foreach (var t in generated) l.Add(t);
        });
        _live.UpdateTiles(_list.Tiles);
        _notice.Show($"Applied {picked.Preset.Title()}", 2);
    }

    // ------------------------------------------------------------------ the list

    /// The stored list, or the starter set the first time there's a bot to make it for (the roster may still be on
    /// its way: up to 6 s, as the Mac).
    private void LoadList()
    {
        _list = QuickTileStore.Load(QuickActionsFeature.Store);
        _currentPage = QuickTileStore.CurrentPage(QuickActionsFeature.Store);
        if (_list.AllPages.All(p => p.Id != _currentPage)) _currentPage = FavoritePage.MainId;
        _hideOtherGateways = QuickTileStore.HidesOtherGateways(QuickActionsFeature.Store);
        if (_list.Tiles.Count > 0 || _list.Seeded) { Reload(); return; }
        _seeding = true;
        Reload();
        var cts = _seedWait = new CancellationTokenSource();
        _ = SeedAsync(cts.Token);
    }

    private async Task SeedAsync(CancellationToken ct)
    {
        for (var i = 0; i < 30 && !ct.IsCancellationRequested; i++)
        {
            if (SeedIfReady()) break;
            try { await Task.Delay(200, ct); } catch (TaskCanceledException) { return; }
        }
        _seeding = false;
        Reload();
    }

    /// Seeds from the roster's first bot once it is known. True: done (seeded, or nothing to seed).
    private bool SeedIfReady()
    {
        var stored = QuickTileStore.Load(QuickActionsFeature.Store);
        if (stored.Tiles.Count > 0 || stored.Seeded) { _list = stored; return true; }
        if (ListsHub.Current is not { } hub || !hub.Bots.HasRoster || hub.Bots.Rows.FirstOrDefault() is not { } first) return false;
        var shown = QuickTileStore.ListToShow(stored, (first.Id, first.Model.DisplayName));
        if (shown.Seeded)
        {
            QuickTileStore.Save(shown.List, QuickActionsFeature.Store);
            AppLog.Note("quick-actions", "seeded the starter set");
        }
        _list = shown.List;
        return true;
    }

    private void Change(Action<QuickTileList> edit)
    {
        var next = _list.Copy();
        edit(next);
        _list = next;
        QuickTileStore.Save(_list, QuickActionsFeature.Store);
        _live.UpdateTiles(_list.Tiles);
        Reload();
    }

    private void Reload()
    {
        var stored = QuickTileStore.Load(QuickActionsFeature.Store);
        if (stored.Seeded || stored.Tiles.Count > 0 || stored.Pages.Count > 0) _list = stored;
        if (_list.AllPages.All(p => p.Id != _currentPage)) _currentPage = FavoritePage.MainId;
        var pageTiles = _list.TilesOn(_currentPage);
        if (pageTiles.Count == 0 && _list.Tiles.Count == 0) _editing = false;
        _edit.Content = _editing ? "Done" : "Edit";
        if (_editing) _edit.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        else _edit.ClearValue(StyleProperty);
        _edit.Visibility = _list.Tiles.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        _pagesBar.Update(_list.AllPages, _currentPage, QuickTileLayout.SideFor(_scroll.ActualWidth));
        Draw();
    }

    private List<QuickTile> CurrentVisibleTiles(QuickTileWorld? world = null)
    {
        var searching = _searchQuery.Length > 0;
        var tiles = _list.VisibleTiles(_currentPage, includeCollapsed: _editing || searching);
        if (_hideOtherGateways && world != null)
            tiles = tiles.Where(t => !QuickTileRules.IsOtherGateway(t, world)).ToList();
        if (searching)
        {
            var q = _searchQuery;
            tiles = tiles.Where(t => t.Known != QuickTileKind.Section && (
                t.Name.Contains(q, StringComparison.OrdinalIgnoreCase)
                || t.Subtitle(BotName(t.Bot)).Contains(q, StringComparison.OrdinalIgnoreCase)
                || (t.BotName?.Contains(q, StringComparison.OrdinalIgnoreCase) ?? false)
                || (t.Command?.Contains(q, StringComparison.OrdinalIgnoreCase) ?? false)
                || (t.Url?.Contains(q, StringComparison.OrdinalIgnoreCase) ?? false))).ToList();
        }
        return tiles;
    }

    // ------------------------------------------------------------------ the grid (QuickTileLayout + 2D Bento)

    /// Windows' text size (Settings › Accessibility › Text size, 1.0–2.25); 1 when it can't be read.
    private double TextScale()
    {
        try { return _ui.TextScaleFactor; }
        catch (Exception) { return 1; }
    }

    private (bool Stacked, double Side, double Gap) Key() => QuickTileLayout.Key(_scroll.ActualWidth, TextScale());

    /// UISettings raises this off the UI thread.
    private void TextScaleChanged(Windows.UI.ViewManagement.UISettings sender, object args)
    {
        if (AppShutdown.Stopping) return;
        DispatcherQueue?.TryEnqueue(() =>
        {
            if (AppShutdown.Stopping || !IsLoaded) return;
            if (_drawnKey != Key()) Draw();
        });
    }

    /// Lays out the current page's tiles: 1 full-width column via `QuickTileLayout.Fit` at accessibility text sizes
    /// (`plan.Stacked`), and the responsive 2–5 column 2D Bento canvas (`QuickTileLayout.Compute`) on normal widths.
    /// Keeps keyboard focus on its stable automation id across every redraw.
    private void Draw()
    {
        var focused = XamlRoot != null ? FocusManager.GetFocusedElement(XamlRoot) as Control : null;
        var focusId = focused != null && Within(focused, _grid) ? FocusKey(focused) : null;
        var focusState = focused?.FocusState ?? FocusState.Unfocused;
        if (_focusAfter != null)
        {
            // The menu's item had the keyboard; its flyout gives it back to the old tile as it closes, so wait for that.
            var after = _focusAfter;
            _focusAfter = null;
            DispatcherQueue?.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => Refocus(after, FocusState.Keyboard));
        }
        var scale = TextScale();
        _drawnKey = Key();
        _drawnBentoKey = QuickTileLayout.BentoKey(_scroll.ActualWidth, scale);
        UiTree.DeactivateProgressRings(_grid);
        _grid.Children.Clear();
        _pagesBar.Update(_list.AllPages, _currentPage, QuickTileLayout.SideFor(_scroll.ActualWidth));

        var world = World();
        var visible = CurrentVisibleTiles(world);
        if (visible.Count == 0 && !_editing)
        {
            _grid.Padding = new Thickness(0);
            if (!_seeding) _grid.Children.Add(Empty());
            Refocus(focusId, focusState);
            return;
        }

        var cells = visible.ToList();
        var addIndex = -1;
        if (_editing) { addIndex = cells.Count; cells.Add(QuickTile.Create(QuickTileKind.Page, id: "quick-actions.add")); }
        var plan = QuickTileLayout.Fit(cells, _scroll.ActualWidth, scale);

        if (plan.Stacked)
        {
            _grid.Spacing = plan.Gap;
            _grid.Padding = new Thickness(plan.Side, plan.Top, plan.Side, plan.Bottom);
            foreach (var row in plan.Rows)
            {
                var line = new Grid { ColumnSpacing = plan.Gap };
                for (var c = 0; c < row.Columns; c++)
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                foreach (var slot in row.Slots)
                {
                    FrameworkElement cell = slot.Index == addIndex ? AddTile(plan) : BuildCell(cells[slot.Index], world, plan);
                    Grid.SetColumn(cell, slot.Column);
                    Grid.SetColumnSpan(cell, slot.Span);
                    line.Children.Add(cell);
                }
                _grid.Children.Add(line);
            }
        }
        else
        {
            var usableWidth = Math.Max(240, (_scroll.ActualWidth > 0 ? _scroll.ActualWidth : 800) - 2 * plan.Side);
            var metrics = new QuickTileBentoMetrics(usableWidth, plan.Gap, Stacked: false, Scale: QuickTileLayout.ScaleFor(scale));
            var bento = QuickTileLayout.Compute(visible, metrics, hasAddTile: _editing);
            _grid.Spacing = 0;
            _grid.Padding = new Thickness(plan.Side, plan.Top, plan.Side, plan.Bottom);
            var canvas = new Canvas { Width = usableWidth, Height = Math.Max(0, bento.TotalHeight) };
            foreach (var p in bento.Placements)
            {
                FrameworkElement cell = p.Index == visible.Count ? AddTile(plan) : BuildCell(visible[p.Index], world, plan);
                cell.Width = p.Frame.Width;
                cell.Height = p.Frame.Height;
                Canvas.SetLeft(cell, p.Frame.X);
                Canvas.SetTop(cell, p.Frame.Y);
                canvas.Children.Add(cell);
            }
            _grid.Children.Add(canvas);
        }
        Refocus(focusId, focusState);
    }

    private const string BadgeId = "quick-tile.remove";
    private const string ResizeId = "quick-tile.resize";

    /// The focused element's stable id. Every − badge and resize handle shares one automation id, keyed by its tile.
    private static string? FocusKey(Control focused)
    {
        var id = AutomationProperties.GetAutomationId(focused);
        if (id != BadgeId && id != ResizeId) return id;
        return VisualTreeHelper.GetParent(focused) is Panel { Children.Count: > 0 } holder && holder.Children[0] is Control tile
            ? AutomationProperties.GetAutomationId(tile) + "|" + id : null;
    }

    /// Puts the keyboard back on the redrawn element with this id (a keyboard focus stays a keyboard one). A badge
    /// gone with Edit gives it to its tile.
    private void Refocus(string? id, FocusState state)
    {
        if (string.IsNullOrEmpty(id) || state == FocusState.Unfocused) return;
        string? childId = null;
        var tileId = id;
        if (id.EndsWith("|" + BadgeId, StringComparison.Ordinal)) { childId = BadgeId; tileId = id[..^(BadgeId.Length + 1)]; }
        else if (id.EndsWith("|" + ResizeId, StringComparison.Ordinal)) { childId = ResizeId; tileId = id[..^(ResizeId.Length + 1)]; }
        if (Find(_grid, tileId) is not { } again) return;
        if (childId != null && VisualTreeHelper.GetParent(again) is Panel holder
            && holder.Children.OfType<Control>().FirstOrDefault(c => AutomationProperties.GetAutomationId(c) == childId) is { } b)
            again = b;
        again.Focus(state == FocusState.Pointer ? FocusState.Programmatic : state);
    }

    private static Control? Find(DependencyObject at, string id)
    {
        if (at is Control c && AutomationProperties.GetAutomationId(c) == id) return c;
        if (at is Panel panel)
        {
            foreach (var child in panel.Children) if (Find(child, id) is { } found) return found;
        }
        else if (at is Border { Child: { } inner } && Find(inner, id) is { } inBorder) return inBorder;
        return null;
    }

    private static bool Within(DependencyObject element, DependencyObject ancestor)
    {
        for (var at = element; at != null; at = VisualTreeHelper.GetParent(at))
            if (ReferenceEquals(at, ancestor)) return true;
        return false;
    }

    /// The CURRENT gateway's bots, jobs, pages, pins, rooms, sessions, goals, boards, and gateway identity.
    private QuickTileWorld World()
    {
        var hub = ListsHub.Current;
        var bots = hub != null && hub.Bots.HasRoster
            ? hub.Bots.Rows.GroupBy(r => r.Id).ToDictionary(g => g.Key, g => g.First().Model.DisplayName)
            : null;
        var store = JobsServices.Store;
        var baseWorld = new QuickTileWorld(
            Bots: bots,
            Jobs: QuickTileRun.WorldJobs(KnownJobs(store), store?.Scope ?? "all"),
            Pages: PageChoices().ToDictionary(p => p.Id, p => p.Title));
        return _live.FillWorld(baseWorld, _dashboardTiles);
    }

    /// The Jobs list when it has been read (null: not yet).
    private static IReadOnlyList<CronJob>? KnownJobs(JobsStore? store) => store is { HasList: true } ? store.Jobs : null;

    /// Set Up's jobs (the Mac's JobShortcutCatalog): each job of the list, titled as Jobs shows it.
    private static IReadOnlyList<(string Key, string Name)> Jobs() =>
        JobsServices.Store is { HasList: true } store ? store.Jobs.Select(j => (j.Key, store.Title(j))).ToList() : [];

    /// Every page a tile can open: the sidebar's places that are ported, Quick Actions itself left out.
    private static IReadOnlyList<(string Id, string Title, string Group)> PageChoices() =>
        Places.All.Where(p => p.Id != QuickActionsFeature.PlaceId && p.Page != typeof(PlaceholderPage))
            .GroupBy(p => p.Id).Select(g => g.First())
            .Select(p => (p.Id, p.Title, p.Section == Places.Tools ? "Tools" : "Places")).ToList();

    private static string? BotName(string? profile) =>
        profile != null && ListsHub.Current?.Bots.Bot(profile) is { } row ? row.Model.DisplayName : null;

    // ------------------------------------------------------------------ drawing

    private FrameworkElement Empty()
    {
        var side = QuickTileLayout.Key(_scroll.ActualWidth, TextScale()).Side;
        var panel = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(side, 72, side, 0) };
        if (!QuickTileLayout.StackedAt(TextScale()))
            panel.Children.Add(new FontIcon { Glyph = "\uE734", FontSize = 40, Foreground = PageKit.Secondary });

        var heading = _searchQuery.Length > 0 ? "No Matching Favorites"
            : _currentPage != FavoritePage.MainId ? "This Page Is Empty"
            : "No Favorites";
        var sub = _searchQuery.Length > 0 ? $"Nothing on this page matches “{_searchQuery}”."
            : "Add actions, live cards, Dashboard tiles, or pick a starter preset.";
        panel.Children.Add(new TextBlock { Text = heading, FontSize = 20, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.WrapWholeWords });
        panel.Children.Add(new TextBlock { Text = sub, Foreground = PageKit.Secondary, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.WrapWholeWords });

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
        var add = new Button { Content = "Add Action", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        AutomationProperties.SetAutomationId(add, "quick-actions.empty.add");
        add.Click += (_, _) => _ = ShowAddAsync();
        buttons.Children.Add(add);

        if (_searchQuery.Length == 0)
        {
            var presets = new Button { Content = "Starter Presets…" };
            AutomationProperties.SetAutomationId(presets, "quick-actions.empty.presets");
            presets.Click += (_, _) => _ = ShowPresetsAsync();
            buttons.Children.Add(presets);
        }

        panel.Children.Add(buttons);
        AutomationProperties.SetAutomationId(panel, "quick-actions.empty");
        return panel;
    }

    /// Dispatches a tile to the appropriate visual: collapsible section header, embedded Dashboard tile, native live
    /// card, compact Mini action strip tile, or standard action tile (with Edit chrome when editing).
    private FrameworkElement BuildCell(QuickTile tile, QuickTileWorld world, QuickTileLayoutPlan plan)
    {
        if (tile.Known == QuickTileKind.Section)
        {
            var count = _list.SectionItemCount(tile.Id, _currentPage);
            var header = FavoriteLiveCards.BuildSectionHeader(
                tile,
                count,
                _editing,
                onToggle: () => Change(l => l.ToggleSection(tile.Id)),
                onEdit: () => _ = ShowSetupAsync(tile, isNew: false),
                onRemove: () => Remove(tile.Id));
            header.ContextFlyout = Menu(tile);
            return header;
        }

        var missing = QuickTileRules.Missing(tile, world, QuickTileRules.Windows);

        if (tile.Known == QuickTileKind.DashboardTile)
        {
            var btn = FavoriteTiles.BuildDashboardTile(
                tile,
                _dashboardTiles,
                _editing,
                missing,
                onOpen: () => { if (_editing) _ = ShowSetupAsync(tile, isNew: false); else _ = RunLoggedAsync(tile); },
                onRefresh: () => { if (_dashboardTiles.Pin(tile.Pin) is { } pin) _ = _dashboardTiles.ReadAsync(pin, fresh: true); });
            btn.ContextFlyout = Menu(tile);
            return WrapEditChrome(btn, tile, plan);
        }

        if (tile.Known is { } known && known.IsLiveCard())
        {
            var card = FavoriteLiveCards.BuildLiveCard(
                tile,
                _live,
                BuildLiveCardActions(),
                _editing,
                tile.EffectiveSize,
                plan.Stacked,
                missing);
            card.ContextFlyout = Menu(tile);
            return WrapEditChrome(card, tile, plan);
        }

        if (tile.EffectiveSize == QuickTileSize.Mini && !plan.Stacked)
        {
            var mini = FavoriteLiveCards.BuildMiniFace(
                tile,
                _live,
                _editing,
                missing,
                onClick: () => { if (_editing) _ = ShowSetupAsync(tile, isNew: false); else _ = RunLoggedAsync(tile); });
            mini.ContextFlyout = Menu(tile);
            return WrapEditChrome(mini, tile, plan);
        }

        return Tile(tile, world, plan);
    }

    private FavoriteLiveCards.LiveCardActions BuildLiveCardActions() => new(
        OpenTile: t => { if (_editing) _ = ShowSetupAsync(t, isNew: false); else _ = RunLoggedAsync(t); },
        ToggleTaskDone: id => _ = _live.ToggleTaskDoneAsync(id),
        QuickAddTask: bot => { _dismissSheet?.Invoke(); Navigator.Open("tasks", bot); },
        OpenBotMemo: profile => _ = RunLoggedAsync(QuickTile.Create(QuickTileKind.Memo) with { Bot = profile }),
        OpenBotTalk: profile => _ = RunLoggedAsync(QuickTile.Create(QuickTileKind.Talk) with { Bot = profile }),
        OpenBotNewChat: profile => _ = RunLoggedAsync(QuickTile.Create(QuickTileKind.NewChat) with { Bot = profile, Flag = true }),
        RunJobNow: (tile, job) => _ = RunJobCardNowAsync(tile, job),
        OpenAttention: target => OpenAttentionTarget(target),
        ToggleSection: id => Change(l => l.ToggleSection(id)));

    /// A standard action tile (QuickTileFace): Tall tiles stack icon (or bot avatar when ShowAvatar is on) over
    /// two-line-reserved name and subtitle; Short tiles lay icon beside single-line name and subtitle; stacked
    /// (accessibility sizes) lays words beside the icon up to eight lines each.
    private FrameworkElement Tile(QuickTile tile, QuickTileWorld world, QuickTileLayoutPlan plan)
    {
        var missing = QuickTileRules.Missing(tile, world, QuickTileRules.Windows);
        var subtitle = tile.Subtitle(BotName(tile.Bot));
        var isShort = tile.Short && !plan.Stacked;
        var horizontal = plan.Stacked || isShort;
        var iconSide = isShort ? 30 : 36;

        FrameworkElement icon;
        if (tile.ShowAvatar == true && !string.IsNullOrEmpty(tile.Bot))
        {
            icon = PageKit.Face(tile.Bot, iconSide);
            icon.HorizontalAlignment = HorizontalAlignment.Left;
            icon.VerticalAlignment = horizontal ? VerticalAlignment.Center : VerticalAlignment.Top;
        }
        else
        {
            icon = new Border
            {
                Width = iconSide, Height = iconSide, CornerRadius = new CornerRadius(isShort ? 7 : 8), Background = TileBrush(tile.Tint),
                HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = horizontal ? VerticalAlignment.Center : VerticalAlignment.Top,
                Child = new FontIcon { Glyph = Glyph(tile.Symbol), FontSize = isShort ? 15 : 18, Foreground = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255)) },
            };
        }

        StackPanel Words(string name, string line)
        {
            var titleBlock = new TextBlock
            {
                Text = name, FontSize = isShort ? 14.5 : 16, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.WrapWholeWords,
                MaxLines = plan.Stacked ? 8 : 2, TextTrimming = TextTrimming.CharacterEllipsis,
            };
            if (isShort) titleBlock.MaxLines = 1;
            return new StackPanel
            {
                Spacing = 2, VerticalAlignment = horizontal ? VerticalAlignment.Center : VerticalAlignment.Bottom,
                Children =
                {
                    titleBlock,
                    new TextBlock
                    {
                        Text = line, FontSize = isShort ? 12 : 13, Foreground = PageKit.Secondary, TextWrapping = TextWrapping.WrapWholeWords,
                        MaxLines = plan.Stacked ? 8 : 1, TextTrimming = TextTrimming.CharacterEllipsis,
                    },
                },
            };
        }

        var words = new Grid();
        if (!horizontal)
        {
            // Two name lines and a subtitle reserved, unseen and unread; the words at its foot.
            var reserve = Words("A\nA", "A");
            reserve.Opacity = 0;
            reserve.IsHitTestVisible = false;
            AutomationProperties.SetAccessibilityView(reserve, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            words.Children.Add(reserve);
        }
        words.Children.Add(Words(string.IsNullOrEmpty(tile.Name) ? " " : tile.Name, subtitle));

        var face = new Grid { Opacity = missing == null ? 1 : 0.5, HorizontalAlignment = HorizontalAlignment.Stretch };
        if (horizontal)
        {
            face.ColumnSpacing = isShort ? 10 : 12;
            face.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            face.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            words.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(words, 1);
        }
        else
        {
            face.RowSpacing = 10;
            face.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            face.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(words, 1);
        }
        face.Children.Add(icon);
        face.Children.Add(words);

        // Live page badge or running/feedback indicator in top-right corner
        if (_live.FeedbackByTile.TryGetValue(tile.Id, out var fb))
            face.Children.Add(FavoriteLiveCards.BuildFeedbackOverlay(fb));
        else if (_live.RunningTiles.Contains(tile.Id))
            face.Children.Add(FavoriteLiveCards.BuildRunningOverlay());
        else if (tile.Known == QuickTileKind.Page && _live.PageBadgeFor(tile.Page) is { } badge)
        {
            var pill = FavoriteLiveCards.BuildBadgePill(badge.Text, badge.Urgent);
            pill.HorizontalAlignment = HorizontalAlignment.Right;
            pill.VerticalAlignment = VerticalAlignment.Top;
            if (horizontal) Grid.SetColumn(pill, 1);
            face.Children.Add(pill);
        }

        var button = new Button
        {
            Content = face, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = isShort ? new Thickness(14, 10, 14, 10) : new Thickness(16, 14, 16, 14), CornerRadius = new CornerRadius(14),
            Background = PageKit.Brush("CardBackgroundFillColorDefaultBrush"), BorderBrush = PageKit.Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetAutomationId(button, "quick-tile-" + tile.Id);
        AutomationProperties.SetName(button, $"{tile.Name}, {subtitle}");
        if (missing != null) AutomationProperties.SetItemStatus(button, "Unavailable");
        button.Click += (_, _) =>
        {
            if (_editing) _ = ShowSetupAsync(tile, isNew: false);
            else _ = RunLoggedAsync(tile);
        };
        button.ContextFlyout = Menu(tile);
        return WrapEditChrome(button, tile, plan);
    }

    private FrameworkElement WrapEditChrome(Button button, QuickTile tile, QuickTileLayoutPlan plan)
    {
        if (!_editing) return button;
        var holder = new Grid();
        holder.Children.Add(button);
        var badge = new Button
        {
            Content = new FontIcon { Glyph = "\uE738", FontSize = 12, Foreground = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255)) },
            Width = 26, Height = 26, Padding = new Thickness(0), CornerRadius = new CornerRadius(13),
            Background = new SolidColorBrush(Color.FromArgb(255, 0xFF, 0x3B, 0x30)), BorderThickness = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(-8, -8, 0, 0),
        };
        AutomationProperties.SetAutomationId(badge, BadgeId);
        AutomationProperties.SetName(badge, $"Remove {tile.Name}");
        badge.Click += (_, _) => Remove(tile.Id);
        holder.Children.Add(badge);

        if (!plan.Stacked)
        {
            var resize = new Button
            {
                Content = new FontIcon { Glyph = "\uE740", FontSize = 10, Foreground = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255)) },
                Width = 24, Height = 24, Padding = new Thickness(0), CornerRadius = new CornerRadius(12),
                Background = PageKit.Brush("AccentFillColorDefaultBrush"), BorderThickness = new Thickness(0),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, -6, -6),
            };
            AutomationProperties.SetAutomationId(resize, ResizeId);
            AutomationProperties.SetName(resize, $"Resize {tile.Name}");
            WireResizeHandle(resize, holder, tile);
            holder.Children.Add(resize);
        }
        return holder;
    }

    /// Wires Edit's blue corner resize handle for both click (cycles valid sizes for this tile kind) and drag.
    private void WireResizeHandle(Button resize, FrameworkElement cell, QuickTile tile)
    {
        var id = tile.Id;
        uint? pointer = null;
        Point startPt = default;
        bool startWide = tile.Wide, startShort = tile.Short, dragged = false;
        double startW = 160, startH = 100;

        resize.PointerPressed += (_, e) =>
        {
            pointer = e.Pointer.PointerId;
            startPt = e.GetCurrentPoint(_grid).Position;
            var current = _list.Tiles.FirstOrDefault(t => t.Id == id) ?? tile;
            startWide = current.Wide;
            startShort = current.Short;
            startW = cell.ActualWidth > 0 ? cell.ActualWidth : 160;
            startH = cell.ActualHeight > 0 ? cell.ActualHeight : 100;
            dragged = false;
            resize.CapturePointer(e.Pointer);
            e.Handled = true;
        };
        resize.PointerMoved += (_, e) =>
        {
            if (pointer != e.Pointer.PointerId) return;
            var pos = e.GetCurrentPoint(_grid).Position;
            var dx = pos.X - startPt.X;
            var dy = pos.Y - startPt.Y;
            if (Math.Abs(dx) > 6 || Math.Abs(dy) > 6) dragged = true;
            if (!dragged) return;
            var current = _list.Tiles.FirstOrDefault(t => t.Id == id) ?? tile;
            if (current.Known is { } k && k.SupportsMultiRowSize())
            {
                var wide = startWide ? dx > -startW * 0.25 : dx > startW * 0.3;
                var tall = dy > startH * 0.3;
                var target = tall ? (wide ? QuickTileSize.Large : QuickTileSize.TallCard) : (wide ? QuickTileSize.Wide : QuickTileSize.Small);
                SetSize(id, target);
            }
            else
            {
                var wide = startWide ? dx > -startW * 0.25 : dx > startW * 0.3;
                var isShort = startShort ? dy < startH * 0.3 : dy < -startH * 0.3;
                SetDimensions(id, wide, isShort);
            }
            e.Handled = true;
        };
        void EndDrag(object sender, PointerRoutedEventArgs e)
        {
            if (pointer != e.Pointer.PointerId) return;
            pointer = null;
            resize.ReleasePointerCapture(e.Pointer);
            e.Handled = true;
        }
        resize.PointerReleased += EndDrag;
        resize.PointerCaptureLost += EndDrag;
        resize.Click += (_, _) =>
        {
            if (dragged) { dragged = false; return; }
            FocusTileAfter(id);
            var current = _list.Tiles.FirstOrDefault(t => t.Id == id) ?? tile;
            var choices = QuickTileSizes.Choices(current.Known);
            var idx = choices.ToList().FindIndex(s => s == current.EffectiveSize);
            var next = choices[(idx + 1) % choices.Count];
            SetSize(id, next);
        };
    }

    private void FocusTileAfter(string id) => _focusAfter = "quick-tile-" + id;

    /// The dashed ＋ Add Action tile (shown while editing; always small).
    private FrameworkElement AddTile(QuickTileLayoutPlan plan)
    {
        var accent = PageKit.Brush("AccentTextFillColorPrimaryBrush");
        var face = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12) };
        face.Children.Add(new FontIcon { Glyph = "\uE710", FontSize = 18, Foreground = accent });
        face.Children.Add(new TextBlock { Text = "Add Action", FontWeight = FontWeights.SemiBold, Foreground = accent, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.WrapWholeWords });
        // At least 104 tall, with the text (HQFont.scaled(104)); stacked it is a full-width row like the tiles.
        var grid = new Grid { MinHeight = plan.AddMinHeight };
        grid.Children.Add(new Rectangle { Stroke = accent, StrokeThickness = 1.5, StrokeDashArray = [4, 3], RadiusX = 14, RadiusY = 14 });
        grid.Children.Add(face);
        var button = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch, Padding = new Thickness(0), Background = null, BorderThickness = new Thickness(0),
        };
        AutomationProperties.SetAutomationId(button, "quick-actions.add-tile");
        AutomationProperties.SetName(button, "Add Action");
        button.Click += (_, _) => _ = ShowAddAsync();
        return button;
    }

    /// Context menu for tiles & sections: size submenu (all 7 valid sizes), Tall/Short, Expand/Collapse, Duplicate,
    /// Move to Page, Move Up/Down, Edit…, and Remove.
    private MenuFlyout Menu(QuickTile tile)
    {
        var menu = new MenuFlyout();
        var id = tile.Id;
        MenuFlyoutItem Item(string text, string glyph, Action run)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            item.Click += (_, _) => run();
            return item;
        }

        if (tile.Known == QuickTileKind.Section)
        {
            var collapsed = tile.Collapsed == true;
            menu.Items.Add(Item(collapsed ? "Expand Section" : "Collapse Section", collapsed ? "\uE70D" : "\uE70E", () => Change(l => l.ToggleSection(id))));
            menu.Items.Add(Item("Edit…", "\uE9E9", () => _ = ShowSetupAsync(tile, isNew: false)));
            AppendMoveToPageSubmenu(menu, tile);
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Item("Remove", "\uE738", () => Remove(id)));
            return menu;
        }

        if (!_editing)
        {
            var small = new RadioMenuFlyoutItem { Text = "Small", GroupName = "size", IsChecked = tile.EffectiveSize == QuickTileSize.Small };
            small.Click += (_, _) => { _focusAfter = "quick-tile-" + id; SetSize(id, QuickTileSize.Small); };
            var wide = new RadioMenuFlyoutItem { Text = "Wide", GroupName = "size", IsChecked = tile.EffectiveSize == QuickTileSize.Wide };
            wide.Click += (_, _) => { _focusAfter = "quick-tile-" + id; SetSize(id, QuickTileSize.Wide); };
            menu.Items.Add(small);
            menu.Items.Add(wide);

            var sizeSub = new MenuFlyoutSubItem { Text = "More Sizes", Icon = new FontIcon { Glyph = "\uE740" } };
            foreach (var sz in QuickTileSizes.Choices(tile.Known))
            {
                var target = sz;
                var choice = new RadioMenuFlyoutItem { Text = target.Title(), GroupName = "all-sizes-" + id, IsChecked = tile.EffectiveSize == target };
                choice.Click += (_, _) => { FocusTileAfter(id); SetSize(id, target); };
                sizeSub.Items.Add(choice);
            }
            menu.Items.Add(sizeSub);

            if (tile.Known == null || tile.Known.Value.SupportsShort())
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                var tall = new RadioMenuFlyoutItem { Text = "Tall", GroupName = "height", IsChecked = !tile.Short };
                tall.Click += (_, _) => { FocusTileAfter(id); SetShort(id, false); };
                var shortItem = new RadioMenuFlyoutItem { Text = "Short", GroupName = "height", IsChecked = tile.Short };
                shortItem.Click += (_, _) => { FocusTileAfter(id); SetShort(id, true); };
                menu.Items.Add(tall);
                menu.Items.Add(shortItem);
            }

            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Item("Edit…", "\uE9E9", () => _ = ShowSetupAsync(tile, isNew: false)));
            menu.Items.Add(Item("Duplicate", "\uE8C8", () => Duplicate(id)));
            AppendMoveToPageSubmenu(menu, tile);
            menu.Items.Add(Item("Remove", "\uE738", () => Remove(id)));
            return menu;
        }

        menu.Items.Add(Item("Edit", "\uE9E9", () => _ = ShowSetupAsync(tile, isNew: false)));
        menu.Items.Add(Item("Duplicate", "\uE8C8", () => Duplicate(id)));
        AppendMoveToPageSubmenu(menu, tile);
        menu.Items.Add(Item("Remove", "\uE738", () => Remove(id)));
        var onPage = _list.TilesOn(_currentPage);
        var index = onPage.FindIndex(t => t.Id == id);
        if (index > 0) menu.Items.Add(Item("Move Up", "\uE74A", () => { _focusAfter = "quick-tile-" + id; Step(id, -1); }));
        if (index >= 0 && index < onPage.Count - 1) menu.Items.Add(Item("Move Down", "\uE74B", () => { _focusAfter = "quick-tile-" + id; Step(id, 1); }));
        menu.Items.Add(Item(tile.Wide ? "Make Small" : "Make Wide", tile.Wide ? "\uE73F" : "\uE740", () => { _focusAfter = "quick-tile-" + id; SetWide(id, !tile.Wide); }));
        if (tile.Known == null || tile.Known.Value.SupportsShort())
            menu.Items.Add(Item(tile.Short ? "Make Tall" : "Make Short", tile.Short ? "\uE740" : "\uE73F", () => { FocusTileAfter(id); SetShort(id, !tile.Short); }));
        return menu;
    }

    private void AppendMoveToPageSubmenu(MenuFlyout menu, QuickTile tile)
    {
        if (!_list.HasMultiplePages) return;
        var sub = new MenuFlyoutSubItem { Text = "Move to Page", Icon = new FontIcon { Glyph = "\uE8DE" } };
        foreach (var page in _list.AllPages)
        {
            if (page.Id == tile.ResolvedPageId) continue;
            var targetId = page.Id;
            var targetName = page.Name;
            var item = new MenuFlyoutItem { Text = targetName };
            item.Click += (_, _) =>
            {
                Change(l => l.MoveTile(tile.Id, targetId));
                _notice.Show($"Moved to {targetName}", 2);
            };
            sub.Items.Add(item);
        }
        if (sub.Items.Count > 0) menu.Items.Add(sub);
    }

    // ------------------------------------------------------------------ editing

    private void SetEditing(bool editing)
    {
        _editing = editing && _list.Tiles.Count > 0;
        Reload();
    }

    private void Remove(string id)
    {
        var name = _list.Tiles.FirstOrDefault(t => t.Id == id)?.Name;
        Change(l => l.Remove(id));
        if (name != null) _notice.Show($"Removed {name}", 2);
    }

    private void Duplicate(string id)
    {
        QuickTile? copy = null;
        Change(l => copy = l.Duplicate(id));
        if (copy != null) _notice.Show($"Duplicated {copy.Name}", 2);
    }

    private void SetWide(string id, bool wide) => Change(l => l.SetWide(id, wide));

    private void SetSize(string id, QuickTileSize size) => Change(l => l.SetSize(id, size));

    private void SetShort(string id, bool isShort) => Change(l => l.SetShort(id, isShort));

    private void SetDimensions(string id, bool wide, bool isShort) => Change(l =>
    {
        if (l.Tiles.FirstOrDefault(t => t.Id == id) is { } tile && (tile.Wide != wide || tile.Short != isShort))
            l.Replace(tile with { Wide = wide, Short = isShort, Size = null });
    });

    private void Step(string id, int delta)
    {
        var moved = false;
        Change(l => moved = _list.HasMultiplePages ? l.StepOnPage(id, delta, _currentPage) : l.Step(id, delta));
        if (moved) _notice.Show(delta < 0 ? "Moved up" : "Moved down", 2);
    }

    // ------------------------------------------------------------------ running a tile (QuickActionsRouter.run)

    /// A click's run, its failure logged (by kind only) rather than lost with the unobserved task. [WIN-33]
    private async Task RunLoggedAsync(QuickTile tile)
    {
        try { await RunAsync(tile); }
        catch (Exception x) when (x is not OperationCanceledException) { AppLog.Note("quick-actions", $"tap {tile.Kind} failed: {x.GetType().Name}"); }
    }

    private async Task RunAsync(QuickTile tile)
    {
        var route = QuickTileRoute.Make(tile, World(), QuickTileRules.Windows);
        AppLog.Note("quick-actions", "tap " + tile.Kind);
        var hub = ListsHub.Current;
        switch (route)
        {
            case QuickTileRoute.Unavailable u:
                _notice.Show(u.Words, 4);
                break;

            case QuickTileRoute.NewChat n when hub != null:
            {
                string? chatId = null;
                if (XamlRoot != null && await Prompts.RunAsync(XamlRoot, "Couldn’t Start a New Chat", async () => chatId = await hub.Sessions.NewChatAsync(n.Bot, n.Project))
                    && chatId != null)
                {
                    _dismissSheet?.Invoke();
                    Navigator.Go(new ChatDestination(n.Bot, chatId, "New Chat", n.Send ? "" : (n.Message ?? "")));
                    if (n.Send && !string.IsNullOrWhiteSpace(n.Message))
                    {
                        if (!await QuickTileRun.DeliverAsync(() => QuickActionsFeature.SendInOpenChat(n.Bot, chatId, n.Message)))
                            AppLog.Note("quick-actions", "new chat send: chat never came up");
                    }
                }
                break;
            }

            case QuickTileRoute.Memo m:
                await OpenBotVoiceAsync(m.Profile, tile, startTalk: false);
                break;

            case QuickTileRoute.Talk t:
                await OpenBotVoiceAsync(t.Profile, tile, startTalk: true);
                break;

            case QuickTileRoute.SendInBackground s:
                await SendBackgroundWithFeedbackAsync(tile.Id, s.Profile, tile.BotName, s.Words);
                break;

            case QuickTileRoute.SendInChat s:
                await SendInBotChatAsync(s.Profile, s.Words);
                break;

            case QuickTileRoute.SlashCommand sc:
                await SendInBotChatAsync(sc.Profile, sc.Command);
                break;

            case QuickTileRoute.QuickAsk qa:
            {
                var who = BotName(qa.Profile) ?? tile.BotName ?? qa.Profile;
                var result = await FavoriteQuickAskDialog.ShowAsync(XamlRoot, qa.Profile, who, qa.DefaultOpen);
                if (result == null) break;
                if (result.OpenChat) await SendInBotChatAsync(qa.Profile, result.Message);
                else await SendBackgroundWithFeedbackAsync(tile.Id, qa.Profile, who, result.Message);
                break;
            }

            case QuickTileRoute.RunJob r:
                await RunJobWithFeedbackAsync(tile.Id, r.Key, r.Name);
                break;

            case QuickTileRoute.OpenChat o:
                if (hub?.Bots.Bot(o.Profile) is { } row) { _dismissSheet?.Invoke(); Navigator.Go(new BotChatDestination(row.Model)); }
                else await NoticeAsync(QuickTileRules.MissingBot(tile));
                break;

            case QuickTileRoute.NewTask nt:
                _dismissSheet?.Invoke();
                Navigator.Open("tasks", nt.Bot);
                break;

            case QuickTileRoute.Page p:
                if (Places.All.Any(x => x.Id == p.Id && x.Page != typeof(PlaceholderPage))) { _dismissSheet?.Invoke(); Navigator.Open(p.Id); }
                else await NoticeAsync(QuickTileRules.MissingPage(tile));
                break;

            case QuickTileRoute.Search:
                _dismissSheet?.Invoke();
                OpenQuicklyPanel.Show(XamlRoot, hub, new OpenQuicklyPanel.ShellActions(() => _ = NewChatAsync(hub), () => Navigator.Open("profiles", "new")));
                break;

            case QuickTileRoute.DashboardTile dt:
                OpenDashboardTileViewer(tile, dt.Id);
                break;

            case QuickTileRoute.TasksView tv:
                _dismissSheet?.Invoke();
                Navigator.Open("tasks", tv.Key);
                break;

            case QuickTileRoute.Goal g:
                _dismissSheet?.Invoke();
                Navigator.Open("tasks", "goal:" + g.Id);
                break;

            case QuickTileRoute.NeedsYou:
                if (_live.AttentionItems(1).FirstOrDefault() is { } firstAttn) OpenAttentionTarget(firstAttn.Target);
                else { _dismissSheet?.Invoke(); Navigator.Open("bots"); }
                break;

            case QuickTileRoute.GroupChat gc:
                _dismissSheet?.Invoke();
                Navigator.Go(new RoomDestination(gc.Key));
                break;

            case QuickTileRoute.ChatSession cs:
                _dismissSheet?.Invoke();
                Navigator.Go(new ChatDestination(cs.Profile, cs.SessionId, tile.SessionTitle ?? tile.Name));
                break;

            case QuickTileRoute.JobDetail:
                _dismissSheet?.Invoke();
                Navigator.Open("jobs");
                break;

            case QuickTileRoute.Kanban kb:
                if (!string.IsNullOrEmpty(kb.Board) && AppState.Client is { } kClient)
                    new FileKanbanPrefs().Set(KanbanStore.SlugKey(kClient.AccountId), kb.Board);
                _dismissSheet?.Invoke();
                Navigator.Open("kanban", kb.Status);
                break;

            case QuickTileRoute.GatewayStatus:
                _dismissSheet?.Invoke();
                Navigator.Open("command-center");
                break;

            case QuickTileRoute.Usage:
                _dismissSheet?.Invoke();
                Navigator.Open("usage");
                break;

            case QuickTileRoute.DashboardPage dp:
                if (AppState.Client is { } dClient) TilesPage.PinsFor(dClient).CurrentPage = dp.Id;
                _dismissSheet?.Invoke();
                Navigator.Open("tiles");
                break;

            case QuickTileRoute.FilesFolder ff:
                if (AppState.Client is { } fClient)
                    WorkspaceRoot.SetChosen(FilePreferences.Shared, ff.Path, fClient.AccountId, ff.Profile ?? "default");
                _dismissSheet?.Invoke();
                Navigator.Open("files");
                break;

            case QuickTileRoute.Link link:
                await Launcher.LaunchUriAsync(link.Url);
                break;

            case QuickTileRoute.Routine routine:
                await RunRoutineWithFeedbackAsync(tile.Id, routine);
                break;

            case QuickTileRoute.ToggleSection ts:
                Change(l => l.ToggleSection(ts.Id));
                break;

            default:
                _notice.Show(QuickTileRules.NewerApp, 4);
                break;
        }
    }

    private async Task OpenBotVoiceAsync(string profile, QuickTile tile, bool startTalk)
    {
        var hub = ListsHub.Current;
        if (hub?.Bots.Bot(profile) is not { } botRow)
        {
            await NoticeAsync(QuickTileRules.MissingBot(tile));
            return;
        }
        string? botChat = null;
        try { botChat = await hub.Bots.BotChatIdAsync(profile); }
        catch (Exception x) when (x is not OperationCanceledException) { }
        _dismissSheet?.Invoke();
        Navigator.Go(new BotChatDestination(botRow.Model));

        ChatContext? openCtx = null;
        await QuickTileRun.DeliverAsync(() =>
        {
            openCtx = (botChat != null ? QuickActionsFeature.FindOpenChat(profile, botChat) : null)
                ?? QuickActionsFeature.FindOpenBotChat(profile);
            return openCtx != null;
        });
        if (openCtx == null) return;

        if (startTalk)
        {
            TalkFeature.StartTalk(openCtx);
        }
        else
        {
            VoiceMemosFeature.EnsureStarted();
            var mic = openCtx.ComposerTrailing.Children.OfType<Control>()
                .FirstOrDefault(c => AutomationProperties.GetAutomationId(c) == MemoMicControl.AutomationId);
            mic?.Focus(FocusState.Programmatic);
        }
    }

    private async Task SendInBotChatAsync(string profile, string words)
    {
        var hub = ListsHub.Current;
        if (hub?.Bots.Bot(profile) is not { } sendRow)
        {
            await NoticeAsync($"Hermes HQ has no bot named “{profile}”.", "Couldn’t Start a New Chat");
            return;
        }
        string? botChat = null;
        try { botChat = await hub.Bots.BotChatIdAsync(profile); }
        catch (Exception x) when (x is not OperationCanceledException) { /* opening the chat says why */ }
        _dismissSheet?.Invoke();
        Navigator.Go(new BotChatDestination(sendRow.Model));
        if (botChat == null) return;
        if (!await QuickTileRun.DeliverAsync(() => QuickActionsFeature.SendInOpenChat(profile, botChat, words)))
            AppLog.Note("quick-actions", "send in bot chat: the chat never came up for its words");
    }

    private async Task SendBackgroundWithFeedbackAsync(string tileId, string profile, string? fallbackBotName, string words)
    {
        var hub = ListsHub.Current;
        if (AppState.Client is not { } client || hub == null)
        {
            var err = new QuickTileSaid.Failed("Open Hermes HQ once so it knows your bots, then run the shortcut again.");
            _live.RecordFeedback(tileId, ok: false, "Offline");
            Say(err);
            return;
        }
        _live.SetRunning(tileId, true);
        try
        {
            var sendTo = BotName(profile) ?? fallbackBotName ?? profile;
            var sent = await QuickTileRun.SendInBackgroundAsync(client, profile, sendTo, ct => hub.Bots.BotChatIdAsync(profile, ct), words);
            AppLog.Note("quick-actions", sent is QuickTileSaid.Done ? "send: sent" : "send: failed");
            _live.RecordFeedback(tileId, sent is QuickTileSaid.Done, sent is QuickTileSaid.Done ? "Sent" : "Failed");
            Say(sent);
        }
        finally
        {
            _live.SetRunning(tileId, false);
        }
    }

    private async Task RunJobWithFeedbackAsync(string tileId, string key, string name)
    {
        var jobs = JobsServices.Store;
        var target = QuickTileRun.Job(key, jobs?.Scope == "all" ? KnownJobs(jobs) : null);
        if (target is not { } job || (jobs?.Api ?? (AppState.Client is { } c ? new JobsApi(c.Session) : null)) is not { } api)
        {
            _live.RecordFeedback(tileId, ok: false, "Missing");
            Say(new QuickTileSaid.Failed($"“{name}” isn’t on this gateway."));
            return;
        }
        _live.SetRunning(tileId, true);
        try
        {
            var ran = await QuickTileRun.RunJobAsync(api, job.Owner, job.Id, name);
            AppLog.Note("quick-actions", ran is QuickTileSaid.Done ? "run job: started" : "run job: refused");
            _live.RecordFeedback(tileId, ran is QuickTileSaid.Done, ran is QuickTileSaid.Done ? "Running" : "Failed");
            Say(ran);
            if (jobs != null) _ = jobs.RefreshAsync();
        }
        finally
        {
            _live.SetRunning(tileId, false);
        }
    }

    private Task RunJobCardNowAsync(QuickTile tile, CronJob job) =>
        RunJobWithFeedbackAsync(tile.Id, job.Key, JobsServices.Store?.Title(job) ?? tile.Name);

    private async Task RunRoutineWithFeedbackAsync(string tileId, QuickTileRoute.Routine routine)
    {
        var hub = ListsHub.Current;
        var jobs = JobsServices.Store;
        var jobsApi = jobs?.Api ?? (AppState.Client is { } c ? new JobsApi(c.Session) : null);
        _live.SetRunning(tileId, true);
        try
        {
            var outcome = await QuickTileRun.RunRoutineAsync(
                routine.Steps,
                routine.Name,
                runJob: async (step, ct) =>
                {
                    var key = step.Job ?? "";
                    var target = QuickTileRun.Job(key, jobs?.Scope == "all" ? KnownJobs(jobs) : null);
                    if (target is not { } j || jobsApi == null)
                        return new QuickTileSaid.Failed($"“{step.JobName ?? "Job"}” isn’t on this gateway.");
                    var ran = await QuickTileRun.RunJobAsync(jobsApi, j.Owner, j.Id, step.JobName ?? "Job", ct: ct);
                    if (jobs != null) _ = jobs.RefreshAsync();
                    return ran;
                },
                sendMessage: async (step, ct) =>
                {
                    if (AppState.Client is not { } client || hub == null || string.IsNullOrEmpty(step.Bot))
                        return new QuickTileSaid.Failed("Open Hermes HQ once so it knows your bots.");
                    var who = BotName(step.Bot) ?? step.Bot;
                    return await QuickTileRun.SendInBackgroundAsync(client, step.Bot, who, token => hub.Bots.BotChatIdAsync(step.Bot, token), step.Message ?? "", ct);
                },
                runForeground: async (step, _) =>
                {
                    switch (step.KnownKind)
                    {
                        case QuickRoutineStepKind.SlashCommand when !string.IsNullOrEmpty(step.Bot) && !string.IsNullOrEmpty(step.Command):
                            await SendInBotChatAsync(step.Bot, step.Command);
                            break;
                        case QuickRoutineStepKind.OpenPage when !string.IsNullOrEmpty(step.Page):
                            _dismissSheet?.Invoke();
                            Navigator.Open(step.Page);
                            break;
                        case QuickRoutineStepKind.OpenChat when !string.IsNullOrEmpty(step.Bot) && hub?.Bots.Bot(step.Bot) is { } br:
                            _dismissSheet?.Invoke();
                            Navigator.Go(new BotChatDestination(br.Model));
                            break;
                        case QuickRoutineStepKind.OpenTile when !string.IsNullOrEmpty(step.Pin):
                            OpenDashboardTileViewer(QuickTile.Create(QuickTileKind.DashboardTile, name: step.PinName ?? "Tile") with { Pin = step.Pin, PinName = step.PinName }, step.Pin);
                            break;
                    }
                });
            _live.RecordFeedback(tileId, outcome.Ok, outcome.BadgeText);
            if (outcome.Said != null) Say(outcome.Said);
        }
        finally
        {
            _live.SetRunning(tileId, false);
        }
    }

    private void OpenAttentionTarget(FavoritesLiveModel.AttentionTarget target)
    {
        _dismissSheet?.Invoke();
        switch (target)
        {
            case FavoritesLiveModel.AttentionTarget.BotChat bc when ListsHub.Current?.Bots.Bot(bc.Profile) is { } row:
                Navigator.Go(new BotChatDestination(row.Model));
                break;
            case FavoritesLiveModel.AttentionTarget.Tasks:
                Navigator.Open("tasks");
                break;
            case FavoritesLiveModel.AttentionTarget.Kanban:
                Navigator.Open("kanban");
                break;
            case FavoritesLiveModel.AttentionTarget.Jobs:
                Navigator.Open("jobs");
                break;
            case FavoritesLiveModel.AttentionTarget.Subagents:
                Navigator.Open("subagents");
                break;
            case FavoritesLiveModel.AttentionTarget.CommandCenter:
                Navigator.Open("command-center");
                break;
            default:
                Navigator.Open("bots");
                break;
        }
    }

    private void OpenDashboardTileViewer(QuickTile tile, string pinId)
    {
        if (AppState.Client is not { } client || _dashboardTiles.Pin(pinId) is not { } pin)
        {
            _notice.Show(QuickTileRules.NotOnDashboard(tile), 4);
            return;
        }
        CloseViewer();
        var viewer = new TileViewer(client.Session, pin, tile.ShownName(_dashboardTiles.Name(pin)), status: null);
        viewer.Closed += CloseViewer;
        _viewer = viewer;
        _overlay.Children.Add(viewer);
    }

    private void CloseViewer()
    {
        if (_viewer is not { } v) return;
        _viewer = null;
        v.Closed -= CloseViewer;
        _overlay.Children.Remove(v);
        v.Close();
    }

    /// Open Quickly's New Chat, as Ctrl+N starts one: the bot on show, else the first.
    private async Task NewChatAsync(ListsHub? hub)
    {
        if (hub == null || XamlRoot == null) return;
        var bot = hub.Bots.VisibleBot ?? hub.Sessions.Selected?.Profile ?? hub.Bots.Layout.Flat.FirstOrDefault()?.Id;
        if (bot == null) return;
        string? id = null;
        if (await Prompts.RunAsync(XamlRoot, "Couldn’t Start a New Chat", async () => id = await hub.Sessions.NewChatAsync(bot)) && id != null)
            Navigator.Go(new ChatDestination(bot, id, "New Chat"));
    }

    private Task NoticeAsync(string message, string title = "Couldn’t Run That Action") => PageKit.ShowAsync(XamlRoot, new ContentDialog
    {
        Title = title, Content = message, CloseButtonText = "OK", DefaultButton = ContentDialogButton.Close,
    });

    /// A background tile's answer (QuickActionsRouter.say): ✓ and what it did, or the reason for 4 s.
    private void Say(QuickTileSaid said)
    {
        switch (said)
        {
            case QuickTileSaid.Done d: _notice.Show("✓ " + d.Words); break;
            case QuickTileSaid.Failed f: _notice.Show(f.Words, 4); break;
        }
    }

    // ------------------------------------------------------------------ Add Action and Set Up

    private async Task ShowAddAsync()
    {
        var dashChoices = QuickActionChoice.DashboardTiles(
            _dashboardTiles.VisiblePins.Select(p => (p.Id, _dashboardTiles.Name(p), p.IsPage ? "chart.xyaxis.line" : "photo")),
            _list);
        var choice = await QuickActionDialogs.ChooseAsync(XamlRoot, QuickActionChoice.Pages(PageChoices()), dashChoices, _dashboardTiles);
        if (choice == null) return;
        var starter = choice.NewTile() with
        {
            PageId = _currentPage == FavoritePage.MainId ? null : _currentPage,
            GatewayId = _hideOtherGateways ? AppState.Client?.AccountId : null,
        };
        var tile = await QuickActionDialogs.SetUpAsync(XamlRoot, starter, isNew: true, Bots(), Jobs(), BuildSetupContext());
        if (tile == null) return;
        Change(l => l.Add(tile));
        _dashboardTiles.EnsureLoaded([tile], fresh: false);
        _notice.Show($"Added {tile.Name}", 2);
    }

    private async Task ShowSetupAsync(QuickTile tile, bool isNew)
    {
        var saved = await QuickActionDialogs.SetUpAsync(XamlRoot, tile, isNew, Bots(), Jobs(), BuildSetupContext());
        if (saved != null) Change(l => l.Replace(saved));
    }

    private QuickActionDialogs.SetupContext BuildSetupContext()
    {
        var hub = ListsHub.Current;
        var projects = hub?.Sessions.ProjectEntries()
            .Where(p => !string.IsNullOrEmpty(p.Key))
            .Select(p => (p.Key, p.Label)).ToList() ?? [];
        var rooms = hub?.Groups.Rows().Where(r => !r.Hidden).Select(r => (r.Id, r.Name)).ToList() ?? [];
        var sessions = hub?.Sessions.LiveSummaries().Take(30).Select(s => (s.Profile, s.Id, s.Title)).ToList() ?? [];
        var goals = _live.Tasks?.Goals.Select(g => (g.Id, g.Shown)).ToList() ?? [];
        var taskViews = new List<(string Key, string Name)> { ("today", "Today"), ("upcoming", "Upcoming"), ("inbox", "Inbox"), ("bots", "Bots") };
        if (_live.Tasks != null)
            taskViews.AddRange(_live.Tasks.Sections.Select(s => ("list:" + s.Id, s.Name)));
        var boards = _live.Kanban?.Boards?.Boards.Select(b => (b.Slug, KanbanModel.BoardTitle(b.Slug, b.Name))).ToList() ?? [];
        var dashPages = _dashboardTiles.Pages.Select(p => (p.Id, p.Name)).ToList();
        var pins = _dashboardTiles.VisiblePins.Select(p => (p.Id, _dashboardTiles.Name(p))).ToList();
        IReadOnlyList<string> favCmds = AppState.Client is { } c ? ComposerServices.Prefs(c.AccountId).FavoriteCommands : [];
        return new QuickActionDialogs.SetupContext(
            Projects: projects,
            Rooms: rooms,
            Sessions: sessions,
            Goals: goals,
            TaskViews: taskViews,
            Boards: boards,
            DashboardPages: dashPages,
            Pages: PageChoices(),
            Pins: pins,
            Prompts: ComposerServices.Prompts.Prompts,
            FavoriteCommands: favCmds);
    }

    private static IReadOnlyList<(string Id, string Name)> Bots() =>
        ListsHub.Current?.Bots.Rows.Select(r => (r.Id, r.Model.DisplayName)).ToList() ?? [];

    // ------------------------------------------------------------------ look (QuickTileLook)

    internal static Brush TileBrush(QuickTileColor color) => color switch
    {
        QuickTileColor.Accent => PageKit.Brush("AccentFillColorDefaultBrush"),
        QuickTileColor.Red => Solid(0xFF, 0x3B, 0x30),
        QuickTileColor.Orange => Solid(0xFF, 0x95, 0x00),
        QuickTileColor.Yellow => Solid(0xFF, 0xCC, 0x00),
        QuickTileColor.Green => Solid(0x34, 0xC7, 0x59),
        QuickTileColor.Teal => Solid(0x30, 0xB0, 0xC7),
        QuickTileColor.Indigo => Solid(0x58, 0x56, 0xD6),
        QuickTileColor.Pink => Solid(0xFF, 0x2D, 0x55),
        _ => Solid(0x8E, 0x8E, 0x93),
    };

    private static SolidColorBrush Solid(byte r, byte g, byte b) => new(Color.FromArgb(255, r, g, b));

    /// Segoe Fluent Icons standing in for the Mac's SF Symbols across all 28 kinds and 12 page icons.
    internal static string Glyph(string symbol) => symbol switch
    {
        "square.and.pencil" => "\uE70F",
        "mic.fill" => "\uE720",
        "waveform" => "\uE8D6",
        "paperplane.fill" => "\uE724",
        "bubble.left.fill" => "\uE8BD",
        "bubble.left.and.bubble.right.fill" => "\uE902",
        "checklist" => "\uE9D5",
        "bolt.fill" => "\uE945",
        "magnifyingglass" => "\uE721",
        "star.fill" => "\uE735",
        "heart.fill" => "\uEB51",
        "house.fill" => "\uE80F",
        "briefcase.fill" => "\uE821",
        "sun.max.fill" => "\uE706",
        "chart.bar.fill" or "chart.xyaxis.line" => "\uE9D2",
        "chevron.left.forwardslash.chevron.right" => "\uE943",
        "sparkles" => "\uE734",
        "globe" => "\uE774",
        "link" => "\uE71B",
        "folder.fill" => "\uE8B7",
        "apple.terminal.fill" or "terminal.fill" => "\uE756",
        "plus.forwardslash.minus" => "\uE948",
        "plus.circle.fill" => "\uE710",
        "list.bullet.rectangle.fill" or "rectangle.3.group.fill" or "rectangle.3.group" => "\uE8FD",
        "text.quote" => "\uE8C1",
        "command" => "\uE765",
        "target" => "\uE7C8",
        "bell.badge.fill" => "\uEA8F",
        "clock.fill" => "\uE823",
        "person.crop.circle.fill" => "\uE77B",
        "server.rack" or "waveform.path.ecg" => "\uE9D9",
        "rectangle.split.3x1.fill" => "\uE8A9",
        "photo" => "\uEB9F",
        "line.3.horizontal" => "\uE700",
        "questionmark.square.dashed" => "\uE9CE",
        _ => "\uF0E2",
    };
}
