using System.Text;
using Hermes.Core;
using Hermes.Core.Artifacts;
using Hermes.Core.Model;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;

namespace HermesHQ.Features.Artifacts;

/// Artifacts (App/Pages/Artifacts/ArtifactsViewController.swift, the Mac's grid [mac-tools]; docs/spec/1x-pages.md §5):
/// files, images and links the bots produced in recent chats, over the whole window. The bar: "Artifacts", All · Images
/// · Files · Links (in the bar while it is 660 wide or more, else the list's first row), "All Bots ⌄" (two bots or more),
/// Search. Pictures are a grid of thumbnails 150 wide or more (All shows the newest 24, then "Show All N Images"); files
/// and links are cards 300 wide or more under day headings that count them ("Saturday 9"); what the gateway can't find
/// folds under "Unavailable". A file opens beside the grid (which narrows to one column of cards) and closes with ✕;
/// a picture opens in its own window, as do a PDF and any other file. ⋯ and right-click: Open, Show in Chat, Share…,
/// Save As…, Copy Path / Link, Remove. Not yet: Pin as Tile (the Tiles row), syncing Remove with the gateway.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class ArtifactsPage : Page, IKeyRefreshing
{
    private const double Inset = ArtifactGridLayout.Inset, Gap = ArtifactGridLayout.Gap, BarFilterLeast = 660, NarrowList = 400;

    private HermesClient? _client;
    private ArtifactsStore? _store;
    private ArtifactPreviews? _previews;
    private ArtifactKind? _filter;
    private string _query = "";
    private int _fileLimit = ArtifactPageWords.FileLimit;
    private bool _unavailableOpen;
    private string? _openingRow;
    private string? _markedId;
    private CancellationTokenSource? _opening;
    private bool _skeletonShown;
    private DispatcherQueueTimer? _skeletonTimer;
    private bool _reloadPending;
    private bool _relayoutPending;
    private ArtifactGridLayout _drawnGrid;
    private readonly List<(Grid Grid, bool Images)> _grids = [];
    private bool? _segmentsWereInBar;
    private List<ArtifactRecord> _visibleImages = [];
    private readonly Dictionary<string, Border> _tiles = [];
    private readonly Dictionary<string, ArtifactRecord> _records = [];

    private readonly Grid _bar = new() { Height = 56, Padding = new Thickness(Inset, 8, 12, 8), ColumnSpacing = 12 };
    private readonly ContentControl _barSegments = new() { IsTabStop = false, VerticalAlignment = VerticalAlignment.Center };
    private readonly DropDownButton _scope = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly AutoSuggestBox _search = new()
    {
        PlaceholderText = ArtifactPageWords.SearchPlaceholder, Width = 220, VerticalAlignment = VerticalAlignment.Center,
        QueryIcon = new SymbolIcon(Symbol.Find),
    };
    private readonly Button _refresh = new() { Content = new FontIcon { Glyph = "\uE72C", FontSize = 14 }, VerticalAlignment = VerticalAlignment.Center };
    private readonly ScrollViewer _scroller = new() { HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly StackPanel _list = new() { Padding = new Thickness(Inset, 4, Inset, 24) };
    private readonly Border _notice = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 20),
        CornerRadius = new CornerRadius(18), Padding = new Thickness(16, 8, 10, 8), Visibility = Visibility.Collapsed,
    };
    private readonly ArtifactFilePane _pane = new() { Visibility = Visibility.Collapsed };
    private readonly ColumnDefinition _listColumn = new() { Width = new GridLength(1, GridUnitType.Star) };
    private readonly ColumnDefinition _paneColumn = new() { Width = new GridLength(0) };
    private DispatcherQueueTimer? _noticeTimer;

    public ArtifactsPage()
    {
        NavigationCacheMode = NavigationCacheMode.Disabled;
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // The bar: the page's name, the segments, then (at the trailing edge) the bot filter, Search and Refresh.
        _bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        // [WIN-50] The Mac's page bar (MacWindow.pageBar, Shell/PageBar.cs): the page-title token and the page's side;
        // the items read All Bots ⌄ · Refresh · Search, the magnifier at the edge (DesktopBars.searchToEdge).
        var title = new TextBlock { Text = ArtifactPageWords.Title, VerticalAlignment = VerticalAlignment.Center };
        HermesHQ.Shell.PageBar.Title(title, "artifacts");
        _bar.Padding = HermesHQ.Shell.PageBar.Padding(8, 8);
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level1);
        _bar.Children.Add(title);
        Grid.SetColumn(_barSegments, 1);
        _bar.Children.Add(_barSegments);
        Grid.SetColumn(_scope, 3);
        AutomationProperties.SetAutomationId(_scope, "pages.scope");
        _bar.Children.Add(_scope);
        Grid.SetColumn(_search, 5);
        AutomationProperties.SetAutomationId(_search, "artifacts.search");
        _search.TextChanged += (_, _) =>
        {
            if (_search.Text == _query) return;
            _query = _search.Text;
            Reload();
        };
        _bar.Children.Add(_search);
        Grid.SetColumn(_refresh, 4);
        _refresh.Style = (Style)Application.Current.Resources["QuietButtonStyle"];
        ToolTipService.SetToolTip(_refresh, "Refresh");
        AutomationProperties.SetName(_refresh, "Refresh");
        AutomationProperties.SetAutomationId(_refresh, "artifacts.refresh");
        _refresh.Click += (_, _) => Pulled();
        _bar.Children.Add(_refresh);
        root.Children.Add(_bar);

        var body = new Grid();
        body.ColumnDefinitions.Add(_listColumn);
        body.ColumnDefinitions.Add(_paneColumn);
        Grid.SetRow(body, 1);
        var listHost = new Grid();
        _scroller.Content = _list;
        AutomationProperties.SetAutomationId(_scroller, "artifacts.list");
        listHost.Children.Add(_scroller);
        _notice.Background = Look.Brush("AcrylicInAppFillColorDefaultBrush");
        _notice.BorderBrush = Look.Brush("CardStrokeColorDefaultBrush");
        _notice.BorderThickness = new Thickness(1);
        listHost.Children.Add(_notice);
        body.Children.Add(listHost);
        Grid.SetColumn(_pane, 1);
        _pane.CloseRequested += CloseFile;
        body.Children.Add(_pane);
        root.Children.Add(body);
        Content = root;

        _scroller.Loaded += (_, _) => QueueRelayout();
        _scroller.SizeChanged += (_, _) => QueueRelayout();
        _scroller.RegisterPropertyChangedCallback(ScrollViewer.ViewportWidthProperty, (_, _) => QueueRelayout());
        var find = new KeyboardAccelerator { Key = VirtualKey.F, Modifiers = VirtualKeyModifiers.Control };
        find.Invoked += (_, e) => { e.Handled = true; _search.Focus(FocusState.Keyboard); };
        var reload = new KeyboardAccelerator { Key = VirtualKey.R, Modifiers = VirtualKeyModifiers.Control };
        reload.Invoked += (_, e) => { e.Handled = true; Pulled(); };
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        KeyboardAccelerators.Add(find);
        KeyboardAccelerators.Add(reload);
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (AppState.Client is not { } client)
        {
            _list.Children.Clear();
            _list.Children.Add(Look.State("\uE91B", ArtifactPageWords.Title, null));
            return;
        }
        _client = client;
        (_store, _previews) = ArtifactsHub.For(client);
        _filter = ArtifactsHub.Prefs(client.AccountId).Filter;
        _store.Changed += StoreChanged;
        _store.Notice += ShowNotice;
        _previews.Updated += PreviewUpdated;
        client.BotsChanged += BotsChanged;
        _store.SetScope(EffectiveScope());
        _previews.RetryTransient();
        _store.PageShown();
        UpdateScopeButton();
        Reload();
        ArtifactActions.Log($"page shown: {_store.Artifacts.Count} kept");
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        if (_store != null) { _store.Changed -= StoreChanged; _store.Notice -= ShowNotice; }
        if (_previews != null) _previews.Updated -= PreviewUpdated;
        if (_client != null) _client.BotsChanged -= BotsChanged;
        _opening?.Cancel();
        _skeletonTimer?.Stop();
        _noticeTimer?.Stop();
        _pane.Clear();
    }

    // ---- scope (the Mac's PagesScope and ScopeMenu)

    private IReadOnlyList<Bot> Bots => _client?.Bots ?? [];

    /// The stored bot, read as All Bots when that bot left the roster.
    private string EffectiveScope()
    {
        if (_client == null) return ArtifactsStore.All;
        var value = ArtifactsHub.Prefs(_client.AccountId).Scope;
        return value == ArtifactsStore.All || Bots.Count == 0 || Bots.Any(b => b.Name == value) ? value : ArtifactsStore.All;
    }

    private string BotName(string profile) =>
        Bots.FirstOrDefault(b => b.Name == profile)?.DisplayName ?? (profile == "default" ? "Hermes" : profile);

    private void BotsChanged() => DispatcherQueue.TryEnqueue(() =>
    {
        if (_store == null) return;
        _store.SetScope(EffectiveScope());
        UpdateScopeButton();
        Reload();
    });

    private void UpdateScopeButton()
    {
        if (_store == null) return;
        var bots = Bots;
        if (bots.Count < 2) { _scope.Visibility = Visibility.Collapsed; return; }
        var current = _store.Scope;
        var title = current == ArtifactsStore.All ? ArtifactPageWords.AllBots : BotName(current);
        _scope.Content = title;
        AutomationProperties.SetName(_scope, ArtifactPageWords.ShowingScope(title));
        var menu = new MenuFlyout();
        RadioMenuFlyoutItem Item(string text, string value)
        {
            var item = new RadioMenuFlyoutItem { Text = text, GroupName = "scope", IsChecked = current == value };
            item.Click += (_, _) => PickScope(value);
            return item;
        }
        menu.Items.Add(Item(ArtifactPageWords.AllBots, ArtifactsStore.All));
        menu.Items.Add(new MenuFlyoutSeparator());
        // All Bots, then the default bot, then roster order.
        foreach (var bot in bots.Where(b => b.Name == "default").Concat(bots.Where(b => b.Name != "default")))
            menu.Items.Add(Item(bot.DisplayName, bot.Name));
        _scope.Flyout = menu;
    }

    private void PickScope(string value)
    {
        if (_store == null || _client == null) return;
        ArtifactsHub.SavePrefs(_client.AccountId, ArtifactsHub.Prefs(_client.AccountId) with { Scope = value });
        _store.SetScope(value);
        _store.PageShown();
        UpdateScopeButton();
        _scroller.ChangeView(null, 0, null, true);
        Reload();
    }

    // ---- segments

    private StackPanel Segments() =>
        Look.Segments(ArtifactPageWords.Segments, Array.IndexOf(ArtifactPageWords.SegmentKinds, _filter), PickSegment, "artifacts.filter");

    private void PickSegment(int index)
    {
        _filter = ArtifactPageWords.SegmentKinds[index];
        _fileLimit = ArtifactPageWords.FileLimit;
        if (_client != null) ArtifactsHub.SavePrefs(_client.AccountId, ArtifactsHub.Prefs(_client.AccountId) with { Filter = _filter });
        Reload();
    }

    private bool SegmentsInBar => _paneColumn.Width.Value == 0 && ActualWidth >= BarFilterLeast;

    // ---- reload

    private void StoreChanged()
    {
        if (_reloadPending) return;
        _reloadPending = true;
        DispatcherQueue.TryEnqueue(() => { _reloadPending = false; Reload(); });
    }

    private bool Matches(ArtifactRecord record)
    {
        var words = _query.Trim();
        if (words.Length == 0) return true;
        return new[] { record.Label, record.Value, record.SessionTitle }.Any(s => s.Contains(words, StringComparison.CurrentCultureIgnoreCase));
    }

    private ArtifactGridLayout MeasureGrid() => ArtifactGridLayout.Fit(_scroller.ActualWidth, _scroller.ViewportWidth,
        _listColumn.Width.IsAbsolute ? _listColumn.Width.Value : null);

    // The native viewport can change without a new outer width. Read both after arrange, not midway through layout.
    private void QueueRelayout()
    {
        if (_relayoutPending) return;
        _relayoutPending = DispatcherQueue.TryEnqueue(() =>
        {
            _relayoutPending = false;
            if (!_scroller.IsLoaded) return;
            if (SegmentsInBar != _segmentsWereInBar) { Reload(); return; }
            var layout = MeasureGrid();
            if (layout == _drawnGrid) return;
            _drawnGrid = layout;
            foreach (var (grid, images) in _grids) PlaceGrid(grid, images);
        });
    }

    private void Reload()
    {
        if (_store == null || _previews == null) return;
        var store = _store;
        _drawnGrid = MeasureGrid();
        _grids.Clear();
        var inBar = SegmentsInBar;
        _segmentsWereInBar = inBar;
        _barSegments.Content = inBar ? Segments() : null;
        _records.Clear();
        foreach (var r in store.Artifacts) _records.TryAdd(r.Id, r);
        _tiles.Clear();
        _list.Children.Clear();
        if (!inBar) _list.Children.Add(new Border { Child = Segments(), Margin = new Thickness(0, 4, 0, 10), HorizontalAlignment = HorizontalAlignment.Left });

        var all = store.Artifacts.Where(Matches).ToList();
        var unavailable = all.Where(r => store.Unavailable.Contains(r.Id)).ToList();
        var available = all.Where(r => !store.Unavailable.Contains(r.Id)).ToList();
        var images = available.Where(r => r.Kind == ArtifactKind.Image && !_previews.IsTiny(r)).ToList();
        var rows = available.Where(r => r.Kind != ArtifactKind.Image && (_filter == null || r.Kind == _filter)).ToList();
        var shown = 0;
        if (_filter is null or ArtifactKind.Image)
        {
            var grid = _filter == null ? images.Take(ArtifactPageWords.ImagesOnAll).ToList() : images;
            _visibleImages = images;
            if (grid.Count > 0)
            {
                if (_filter == null) _list.Children.Add(Head(ArtifactPageWords.ImagesHeader, images.Count));
                _list.Children.Add(ArtifactGrid(grid, images: true));
            }
            if (_filter == null && images.Count > ArtifactPageWords.ImagesOnAll) _list.Children.Add(ShowAllImages(images.Count));
            shown += images.Count;
        }
        else _visibleImages = [];
        if (_filter != ArtifactKind.Image)
        {
            var limited = rows.Take(_fileLimit).ToList();
            foreach (var (day, items) in ArtifactListWords.DaysOf(limited))
            {
                _list.Children.Add(Head(day, items.Count));
                _list.Children.Add(ArtifactGrid(items, images: false));
            }
            if (rows.Count > _fileLimit) _list.Children.Add(LoadMore());
            shown += rows.Count;
        }
        var missing = unavailable.Where(r => _filter == null || r.Kind == _filter).ToList();
        if (missing.Count > 0)
        {
            _list.Children.Add(UnavailableHead(missing.Count));
            if (_unavailableOpen) foreach (var r in missing) _list.Children.Add(Card(r, missing: true));
        }
        var view = ArtifactIndex.View(store.Loaded, shown + missing.Count, store.Refreshing, store.LoadError);
        var showsState = view != ArtifactsView.List;
        if (view == ArtifactsView.Loading)
        {
            if (_skeletonShown) for (var i = 0; i < 8; i++) _list.Children.Add(Skeleton());
            else ScheduleSkeleton();
        }
        else if (view == ArtifactsView.Error)
        {
            var reason = store.LoadError ?? "";
            _list.Children.Add(Look.State("\uE7BA", ArtifactPageWords.CouldntLoad, reason,
                (ArtifactPageWords.TryAgain, () => _ = store.RefreshAsync(explicit_: true)),
                ("Copy Details", () => ArtifactActions.Copy($"{ArtifactPageWords.CouldntLoad}\n{reason}"))));
        }
        else if (view == ArtifactsView.Empty)
        {
            var bot = store.Scope == ArtifactsStore.All ? null : BotName(store.Scope);
            var (title, words) = ArtifactListWords.Empty(_filter, bot, _query);
            var empty = Look.State(_query.Trim().Length == 0 ? "\uE91B" : "\uE721", title, words);
            empty.Margin = new Thickness(24, 80, 24, 24);
            _list.Children.Add(empty);
        }
        if (view != ArtifactsView.Loading) { _skeletonShown = false; _skeletonTimer?.Stop(); }
        // [mac-audit G] A page with nothing in it shows no controls with nothing to act on: while the list is empty with
        // no search, segment or one bot narrowing it, the bot filter and Search leave the bar.
        var bare = showsState && _query.Trim().Length == 0 && _filter == null && store.Scope == ArtifactsStore.All;
        _search.Visibility = bare ? Visibility.Collapsed : Visibility.Visible;
        if (bare) _scope.Visibility = Visibility.Collapsed; else UpdateScopeButton();
    }

    private void ScheduleSkeleton()
    {
        // A pass that found nothing flashed eight grey rows, then "No Artifacts"; most reads answer well inside 1.5 s.
        if (_skeletonTimer is { IsRunning: true }) return;
        _skeletonTimer ??= DispatcherQueue.CreateTimer();
        _skeletonTimer.Interval = TimeSpan.FromSeconds(1.5);
        _skeletonTimer.IsRepeating = false;
        _skeletonTimer.Tick -= SkeletonTick;
        _skeletonTimer.Tick += SkeletonTick;
        _skeletonTimer.Start();
    }

    private void SkeletonTick(DispatcherQueueTimer timer, object _)
    {
        timer.Tick -= SkeletonTick;
        _skeletonShown = true;
        Reload();
    }

    private static Border Skeleton() => new()
    {
        Height = 64, CornerRadius = new CornerRadius(10), Margin = new Thickness(0, 0, 0, Gap), MaxWidth = 420,
        HorizontalAlignment = HorizontalAlignment.Left, Width = 360, Background = Look.Brush("ControlAltFillColorSecondaryBrush"),
    };

    /// "Saturday 9": the heading, then its count in the heads' lighter ink (owner 2026-11-17, Mac calls Q5).
    private static TextBlock Head(string name, int count)
    {
        var head = new TextBlock { FontSize = 14, Margin = new Thickness(0, 14, 0, 8) };
        head.Inlines.Add(new Run { Text = name, FontWeight = FontWeights.SemiBold, Foreground = Look.Brush("TextFillColorSecondaryBrush") });
        head.Inlines.Add(new Run { Text = $" {count}", Foreground = Look.Brush("TextFillColorTertiaryBrush") });
        AutomationProperties.SetHeadingLevel(head, AutomationHeadingLevel.Level2);
        AutomationProperties.SetName(head, $"{name}, {count}");
        return head;
    }

    private Grid ArtifactGrid(List<ArtifactRecord> records, bool images)
    {
        var grid = new Grid { HorizontalAlignment = HorizontalAlignment.Left, ColumnSpacing = Gap, RowSpacing = Gap };
        foreach (var record in records) grid.Children.Add(images ? Tile(record) : Card(record, missing: false));
        PlaceGrid(grid, images);
        _grids.Add((grid, images));
        return grid;
    }

    // Change tracks, not buttons: a resize inside the same column count must resize every cell, too.
    // Use absolute tracks as on the Mac; star widths would redistribute the scroller's lane into the cards.
    private void PlaceGrid(Grid grid, bool images)
    {
        var (columns, width) = images ? _drawnGrid.Images : _drawnGrid.Cards;
        grid.Visibility = width > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (width == 0) return;
        var used = Math.Min(columns, grid.Children.Count);
        if (grid.ColumnDefinitions.Count != used)
        {
            grid.ColumnDefinitions.Clear();
            grid.RowDefinitions.Clear();
            for (var c = 0; c < used; c++) grid.ColumnDefinitions.Add(new ColumnDefinition());
            for (var i = 0; i < grid.Children.Count; i++)
            {
                if (i % columns == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var cell = (FrameworkElement)grid.Children[i];
                Grid.SetRow(cell, i / columns);
                Grid.SetColumn(cell, i % columns);
            }
        }
        var size = new GridLength(width);
        foreach (var column in grid.ColumnDefinitions) column.Width = size;
        if (images) foreach (var row in grid.RowDefinitions) row.Height = size;
    }

    // ---- pictures

    /// A grid tile: the thumbnail, a grey square until it lands, a mark when it failed (a globe when the picture is on
    /// another site and wasn't fetched: the viewer offers Open).
    private Button Tile(ArtifactRecord record)
    {
        var previews = _previews!;
        var face = new Border { CornerRadius = new CornerRadius(10) };
        _tiles[record.Id] = face;
        Paint(face, record);
        face.SizeChanged += (_, e) =>
        {
            if (e.NewSize.Width > 0)
                previews.Request(record, Math.Max(1, (int)(e.NewSize.Width * (XamlRoot?.RasterizationScale ?? 1))));
        };
        var button = new Button
        {
            Content = face, Padding = new Thickness(0), BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(10),
            MinWidth = 0, MinHeight = 0, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        var hosted = previews.StateOf(record) is ArtifactPreviews.Failed { Hosted: true };
        AutomationProperties.SetName(button, ArtifactPageWords.TileSpoken(record, hosted));
        AutomationProperties.SetAutomationId(button, "artifact-tile-" + record.Label);
        button.Click += (_, _) => OpenImage(record);
        button.ContextFlyout = Menu(record, missing: false);
        return button;
    }

    private void Paint(Border face, ArtifactRecord record)
    {
        face.Child = null;
        switch (_previews!.StateOf(record))
        {
            case ArtifactPreviews.Shown shown:
                face.Background = new ImageBrush { ImageSource = shown.Image, Stretch = Stretch.UniformToFill };
                break;
            case ArtifactPreviews.Failed failed:
                face.Background = Look.Brush("ControlAltFillColorSecondaryBrush");
                face.Child = new FontIcon
                {
                    Glyph = failed.Hosted ? "\uE774" : "\uE783", FontSize = 22, Foreground = Look.Brush("TextFillColorTertiaryBrush"),
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                };
                break;
            default:
                face.Background = Look.Brush("ControlAltFillColorSecondaryBrush");
                break;
        }
    }

    private void PreviewUpdated(string id)
    {
        if (_store == null || _previews == null || !_records.TryGetValue(id, out var record)) return;
        if (_previews.StateOf(record) is ArtifactPreviews.Failed { Missing: true } && record.Kind == ArtifactKind.Image)
        {
            _store.MarkUnavailable(id);
            return;
        }
        // An icon-sized picture leaves the grid once it has loaded.
        if (_previews.IsTiny(record)) { StoreChanged(); return; }
        if (_tiles.TryGetValue(id, out var face)) Paint(face, record);
    }

    private Button ShowAllImages(int count)
    {
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"], Margin = new Thickness(-8, 8, 0, 0),
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 6,
                Children =
                {
                    new TextBlock { Text = ArtifactPageWords.ShowAllImages(count), Foreground = Look.Brush("AccentTextFillColorPrimaryBrush") },
                    new FontIcon { Glyph = "\uE76C", FontSize = 11, Foreground = Look.Brush("TextFillColorTertiaryBrush") },
                },
            },
        };
        AutomationProperties.SetAutomationId(button, "artifacts.show-all-images");
        button.Click += (_, _) =>
        {
            _filter = ArtifactKind.Image;
            _scroller.ChangeView(null, 0, null, true);
            Reload();
        };
        return button;
    }

    // ---- files and links

    /// A file or link card: its kind's tile, the name, "&lt;chat&gt; · 6:20 PM", "×3" when named more than once, ⋯. A row
    /// that's Unavailable is drawn plain, its words grey.
    private Grid Card(ArtifactRecord record, bool missing)
    {
        var busy = _openingRow == record.Id;
        var marked = _markedId == record.Id && !missing;
        var tile = new Border
        {
            Width = 36, Height = 36, CornerRadius = new CornerRadius(8), Background = Look.Brush("ControlAltFillColorSecondaryBrush"),
            Child = busy ? new ProgressRing { IsActive = true, Width = 18, Height = 18 }
                : new FontIcon
                {
                    Glyph = missing && record.Kind == ArtifactKind.Image ? "\uE783" : ArtifactActions.Glyph(ArtifactPageWords.Glyph(record)),
                    FontSize = 17, Foreground = Look.Brush(missing ? "TextFillColorTertiaryBrush" : "AccentTextFillColorPrimaryBrush"),
                },
        };
        var name = new TextBlock
        {
            Text = record.Label.Length == 0 ? record.Value : record.Label, FontSize = 14, TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap, Foreground = Look.Brush(missing ? "TextFillColorSecondaryBrush" : "TextFillColorPrimaryBrush"),
        };
        var (chat, when) = ArtifactListWords.Parts(record.SessionTitle, record.Timestamp);
        var subtitle = ArtifactListWords.Subtitle(record.SessionTitle, record.Timestamp);
        var second = new TextBlock
        {
            Text = subtitle, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap,
            Foreground = Look.Brush("TextFillColorSecondaryBrush"),
        };
        // In a narrow card the time goes first when the chat and its time don't both fit ("Project notes · 10…" said neither).
        second.SizeChanged += (_, _) =>
        {
            if (second.IsTextTrimmed && chat.Length > 0 && second.Text == subtitle && when.Length > 0) second.Text = $"{when} · {chat}";
        };
        var words = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center, Children = { name } };
        if (subtitle.Length > 0) words.Children.Add(second);
        var content = new Grid { ColumnSpacing = 12 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.Children.Add(tile);
        Grid.SetColumn(words, 1);
        content.Children.Add(words);
        if (record.RepeatBadge is { } badge)
        {
            // [morepages] "×3": this chat named the file or link three times.
            var count = new TextBlock { Text = badge, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Foreground = Look.Brush("TextFillColorSecondaryBrush") };
            AutomationProperties.SetName(count, record.RepeatSpoken ?? badge);
            AutomationProperties.SetAutomationId(count, "artifact-repeats");
            Grid.SetColumn(count, 2);
            content.Children.Add(count);
        }
        var face = new Button
        {
            Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(10, 10, 48, 10), MinHeight = 64, CornerRadius = new CornerRadius(10),
            Background = missing ? new SolidColorBrush(Microsoft.UI.Colors.Transparent) : Look.Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = missing ? new SolidColorBrush(Microsoft.UI.Colors.Transparent) : Look.Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        if (marked)
        {
            // The open file's card wears the list's soft mark (no tint ring: Mac UI check 2026-11-13).
            var accent = (Windows.UI.Color)Application.Current.Resources["SystemAccentColor"];
            face.Background = new SolidColorBrush(Windows.UI.Color.FromArgb(48, accent.R, accent.G, accent.B));
        }
        AutomationProperties.SetName(face, string.Join(", ", new[] { record.Label, subtitle, record.RepeatSpoken ?? "" }.Where(s => s.Length > 0)));
        AutomationProperties.SetAutomationId(face, "artifact-row-" + record.Label);
        if (marked) AutomationProperties.SetItemStatus(face, "open");
        face.Click += (_, _) => Open(record);
        face.ContextFlyout = Menu(record, missing);
        var more = new Button
        {
            Content = new FontIcon { Glyph = "\uE712", FontSize = 14 }, Width = 36, Height = 36, Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0),
            Style = (Style)Application.Current.Resources["QuietButtonStyle"], Flyout = Menu(record, missing),
        };
        AutomationProperties.SetName(more, $"Actions for {record.Label}");
        var holder = new Grid { Margin = missing ? new Thickness(0, 0, 0, 4) : new Thickness(0) };
        if (missing) holder.MaxWidth = 420;
        holder.Children.Add(face);
        holder.Children.Add(more);
        return holder;
    }

    private Button LoadMore()
    {
        // The Mac loads the next hundred as its spinner row comes into view.
        var ring = new ProgressRing { IsActive = true, Width = 22, Height = 22 };
        var button = new Button { Content = ring, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 0), Style = (Style)Application.Current.Resources["QuietButtonStyle"] };
        AutomationProperties.SetName(button, "Show More");
        void More() { _fileLimit += ArtifactPageWords.FileLimit; Reload(); }
        button.Click += (_, _) => More();
        button.EffectiveViewportChanged += (_, e) => { if (e.BringIntoViewDistanceY < 40 && button.IsLoaded) DispatcherQueue.TryEnqueue(More); };
        return button;
    }

    /// "Unavailable ⌄" open, "Unavailable › 1" folded (the Mac's folding heads, as Sessions' "Recent ⌄").
    private Button UnavailableHead(int count)
    {
        var head = new TextBlock { FontSize = 14 };
        head.Inlines.Add(new Run { Text = "Unavailable", FontWeight = FontWeights.SemiBold, Foreground = Look.Brush("TextFillColorSecondaryBrush") });
        head.Inlines.Add(new Run { Text = _unavailableOpen ? "  \uE70D" : "  \uE76C", FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 10, Foreground = Look.Brush("TextFillColorTertiaryBrush") });
        if (!_unavailableOpen) head.Inlines.Add(new Run { Text = $"  {count}", Foreground = Look.Brush("TextFillColorTertiaryBrush") });
        var button = new Button { Content = head, Style = (Style)Application.Current.Resources["QuietButtonStyle"], Margin = new Thickness(-8, 14, 0, 6) };
        AutomationProperties.SetName(button, ArtifactPageWords.UnavailableSpoken(count));
        AutomationProperties.SetAutomationId(button, "artifacts.unavailable");
        AutomationProperties.SetItemStatus(button, _unavailableOpen ? "open" : "closed");
        button.Click += (_, _) => { _unavailableOpen = !_unavailableOpen; Reload(); };
        return button;
    }

    // ---- the menu

    /// A row's or tile's ⋯ and right-click: Open, Show in Chat, Share…, Save As…, Copy Path / Link, then Remove (the
    /// Mac's order; "Mentioned 3 times" heads it).
    private MenuFlyout Menu(ArtifactRecord record, bool missing)
    {
        var menu = new MenuFlyout();
        if (record.RepeatSpoken is { } spoken) menu.Items.Add(new MenuFlyoutItem { Text = spoken, IsEnabled = false });
        MenuFlyoutItem Item(string text, string glyph, Action act)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            item.Click += (_, _) => act();
            menu.Items.Add(item);
            return item;
        }
        var page = ArtifactFiles.Opening(record).Kind == ArtifactOpeningKind.Html;
        Item(ArtifactPageWords.Open, page ? "\uE774" : "\uE8A7", () => Open(record));
        Item(ArtifactPageWords.ShowInChat, "\uE8BD", () => ArtifactActions.ShowInChat(record));
        if (!missing)
        {
            Item(ArtifactPageWords.Share, "\uE72D", () => Share(record));
            if (record.Kind != ArtifactKind.Link && ArtifactFiles.IsGatewayFile(record)) Item(ArtifactPageWords.SaveAs, "\uE74E", () => SaveAs(record));
        }
        Item(ArtifactPageWords.CopyAction(record.Kind), "\uE8C8", () =>
        {
            ArtifactActions.Copy(record.Value);
            ShowNotice(ArtifactPageWords.Copied, TimeSpan.FromSeconds(1.5));
        });
        menu.Items.Add(new MenuFlyoutSeparator());
        var remove = Item(ArtifactPageWords.Remove, "\uE74D", () => _ = RemoveAsync(record));
        remove.Foreground = Look.Brush("SystemFillColorCriticalBrush");
        AutomationProperties.SetAutomationId(remove, "artifact.remove");
        return menu;
    }

    private async Task RemoveAsync(ArtifactRecord record)
    {
        if (_store == null || !await ArtifactActions.ConfirmRemoveAsync(XamlRoot, record)) return;
        _store.Hidden.Hide(record);
        if (_markedId == record.Id) CloseFile();
        ArtifactActions.Log($"artifact removed ({record.Kind.Raw()})");
        ShowNotice(ArtifactPageWords.Removed, TimeSpan.FromSeconds(1.5));
        Reload();
    }

    // ---- opening (§5.6)

    private string FilesRoot => Path.Combine(ArtifactsHub.CacheRoot(_client!.AccountId), "files");

    private void OpenImage(ArtifactRecord record)
    {
        if (_previews == null) return;
        List<ArtifactRecord> list = _visibleImages.Count == 0 || !_visibleImages.Contains(record) ? [record] : _visibleImages;
        ArtifactImageWindow.Show(list, list.IndexOf(record), _previews);
    }

    /// Opens a file or link: a spinner on its card, "Downloading &lt;name&gt;…" with Cancel after 0.5 s; a newer click
    /// supersedes the old.
    private void Open(ArtifactRecord record)
    {
        if (_store == null) return;
        var opening = ArtifactFiles.Opening(record);
        if (opening.Kind == ArtifactOpeningKind.Link) { ArtifactActions.OpenOutside(record.Value); return; }
        if (opening.Kind == ArtifactOpeningKind.Image) { OpenImage(record); return; }
        var store = _store;
        var source = store.Source;
        var file = ArtifactFiles.PreviewPath(FilesRoot, record);
        StartOpening(record, "Open", async ct =>
        {
            await source.DownloadAsync(record, file, ct);
            store.MarkAvailable(record.Id);
            var bytes = new FileInfo(file).Length;
            if (opening.Kind == ArtifactOpeningKind.Text && ArtifactFiles.OpensAsText(opening, bytes))
            {
                var viewer = new ArtifactTextView(opening.Markdown, _ => ReadText(file)) { Title = record.Label, Record = record };
                viewer.ShareFile = () => Task.FromResult<string?>(file);
                viewer.OpenElsewhere = () => ArtifactActions.OpenInDefaultAppAsync(file, record.Label);
                if (opening.Markdown) WireLinkedNotes(viewer, record);
                ShowBeside(viewer, record);
                return;
            }
            if (opening.Kind == ArtifactOpeningKind.Html)
            {
                var data = await File.ReadAllBytesAsync(file, ct);
                // Source reads its text; a page without a viewport tag previews at the window's width (Share keeps the file).
                var sourceText = Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, ArtifactFiles.TextLimit));
                var preview = file;
                if (ArtifactFiles.PreviewHtml(data) is { } fitted)
                {
                    preview = ArtifactFiles.PreviewCopyPath(file);
                    await File.WriteAllBytesAsync(preview, fitted, ct);
                }
                var page = new ArtifactHtmlView(preview, sourceText) { Title = record.Label, Record = record };
                page.ShareFile = () => Task.FromResult<string?>(file);
                page.OpenInWindow = () => ArtifactFileWindow.Show(preview, record.Label, ArtifactOpeningKind.Html);
                ShowBeside(page, record);
                return;
            }
            // A PDF, a text too long for the viewer, anything else: a window of its own.
            ArtifactFileWindow.Show(file, record.Label, opening.Kind == ArtifactOpeningKind.Text ? ArtifactOpeningKind.Other : opening.Kind);
        });
    }

    private static async Task<string> ReadText(string file)
    {
        var data = await File.ReadAllBytesAsync(file);
        try { return new UTF8Encoding(false, true).GetString(data); }
        catch (DecoderFallbackException) { throw new ArtifactReadException(ArtifactPageWords.NotPlainText); }
    }

    private void ShowBeside(ArtifactViewer viewer, ArtifactRecord record)
    {
        _markedId = record.Id;
        _pane.Visibility = Visibility.Visible;
        _listColumn.Width = new GridLength(NarrowList);
        _paneColumn.Width = new GridLength(1, GridUnitType.Star);
        _pane.Show(viewer);
        Reload();
    }

    private void CloseFile()
    {
        _pane.Clear();
        _pane.Visibility = Visibility.Collapsed;
        _markedId = null;
        _listColumn.Width = new GridLength(1, GridUnitType.Star);
        _paneColumn.Width = new GridLength(0);
        Reload();
    }

    private void Share(ArtifactRecord record)
    {
        if (!ArtifactFiles.IsGatewayFile(record)) { ArtifactActions.ShareLink(record.Value); return; }
        FetchThen(record, "Share", file => ArtifactActions.ShareFileAsync(file, record.Label));
    }

    private void SaveAs(ArtifactRecord record) =>
        FetchThen(record, "Save", async file => { if (await ArtifactActions.SaveAsAsync(file, record.Label)) ShowNotice("Saved", TimeSpan.FromSeconds(1.5)); });

    /// A gateway file is downloaded, then shared or saved, with the same card spinner and notice as Open.
    private void FetchThen(ArtifactRecord record, string verb, Func<string, Task> deliver)
    {
        if (_store == null) return;
        var store = _store;
        var file = ArtifactFiles.PreviewPath(FilesRoot, record);
        StartOpening(record, verb, async ct =>
        {
            await store.Source.DownloadAsync(record, file, ct);
            store.MarkAvailable(record.Id);
            await deliver(file);
        });
    }

    private void StartOpening(ArtifactRecord record, string verb, Func<CancellationToken, Task> work)
    {
        _opening?.Cancel();
        var cts = new CancellationTokenSource();
        _opening = cts;
        _openingRow = record.Id;
        Reload();
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(0.5);
        timer.IsRepeating = false;
        var stopTimer = cts.Token.Register(() => DispatcherQueue.TryEnqueue(timer.Stop));
        void Finish()
        {
            stopTimer.Dispose();
            timer.Stop();
            if (_openingRow == record.Id) { _openingRow = null; HideNotice(); Reload(); }
        }
        timer.Tick += (t, _) =>
        {
            t.Stop();
            if (_openingRow == record.Id && !cts.IsCancellationRequested && !AppShutdown.Stopping)
                ShowNotice(ArtifactPageWords.Downloading(record.Label), TimeSpan.FromSeconds(60), ("Cancel", () => { cts.Cancel(); Finish(); }));
        };
        timer.Start();
        _ = Run();
        async Task Run()
        {
            try
            {
                await work(cts.Token);
                if (!cts.IsCancellationRequested) Finish();
            }
            catch (Exception e)
            {
                // Superseded or cancelled: the newer open owns the spinner and the notice.
                if (cts.IsCancellationRequested) return;
                Finish();
                if (ArtifactFiles.IsMissing(e)) _store?.MarkUnavailable(record.Id);
                ArtifactActions.Log($"{verb.ToLowerInvariant()} failed: {e.GetType().Name}");
                await ArtifactActions.AlertAsync(XamlRoot, ArtifactPageWords.CouldntDo(verb, record.Label), ArtifactFiles.FailureText(e, image: false));
            }
            finally
            {
                stopTimer.Dispose();
                timer.Stop();
            }
        }
    }

    // ---- linked notes (ArtifactLinkedNotes.swift; 3x-morepages §3)

    /// A link in a Markdown note that names another file opens that file over it in the pane, read with the first
    /// note's chat and bot. Back is the note before.
    private void WireLinkedNotes(ArtifactTextView viewer, ArtifactRecord record)
    {
        viewer.LinkOpener = (target, fragment) =>
        {
            var path = ArtifactLinks.LinkedNotePath(record.Value, target);
            if (path.Length == 0) return;
            if (path == record.Value)
            {
                // The note on screen, with only a heading named: scroll, no new page.
                if (fragment != null) viewer.ScrollTo(fragment);
                return;
            }
            OpenLinked(path, fragment, record);
        };
    }

    private void OpenLinked(string path, string? fragment, ArtifactRecord @base)
    {
        if (_store == null) return;
        var source = _store.Source;
        var name = ArtifactLinks.Name(path);
        var record = @base with
        {
            Value = path, Href = path, Label = name, Kind = ArtifactKind.File, Repeats = 1, Id = @base.Id + "\u001F" + path,
        };
        var opening = ArtifactFiles.Opening(record);
        var file = ArtifactFiles.PreviewPath(FilesRoot, record);
        if (opening.Kind != ArtifactOpeningKind.Text)
        {
            // Not text (a PDF, a picture, a page): downloaded, then in its own window over the note.
            _ = OpenElsewhereAsync(record, opening, file);
            return;
        }
        var downloaded = false;
        var viewer = new ArtifactTextView(opening.Markdown, async ct =>
        {
            await source.DownloadAsync(record, file, ct);
            downloaded = true;
            if (new FileInfo(file).Length > ArtifactFiles.TextLimit) throw new ArtifactReadException(ArtifactFiles.TooLargeText);
            return await ReadText(file);
        })
        {
            Title = name, Record = record, LoadingText = ArtifactPageWords.Loading(name), FailureTitle = ArtifactPageWords.CouldntOpenHere(name),
            PendingFragment = fragment,
        };
        viewer.ShareFile = async () =>
        {
            if (!downloaded) await source.DownloadAsync(record, file, CancellationToken.None);
            return file;
        };
        viewer.OpenElsewhere = async () =>
        {
            if (!downloaded) await source.DownloadAsync(record, file, CancellationToken.None);
            await ArtifactActions.OpenInDefaultAppAsync(file, name);
        };
        if (opening.Markdown) WireLinkedNotes(viewer, record);
        _pane.Push(viewer);
    }

    private async Task OpenElsewhereAsync(ArtifactRecord record, ArtifactOpening opening, string file)
    {
        try
        {
            if (opening.Kind == ArtifactOpeningKind.Image)
            {
                ArtifactImageWindow.Show([record], 0, _previews!);
                return;
            }
            await _store!.Source.DownloadAsync(record, file, CancellationToken.None);
            ArtifactFileWindow.Show(file, record.Label, opening.Kind);
        }
        catch (Exception e)
        {
            await ArtifactActions.AlertAsync(XamlRoot, ArtifactPageWords.CouldntOpenHere(record.Label), ArtifactFiles.FailureText(e, image: false));
        }
    }

    // ---- refresh and notices

    /// View › Refresh (Ctrl+R, F5): as its own Ctrl+R, a pull.
    public void KeyRefresh() => Pulled();

    private void Pulled()
    {
        if (_store == null) return;
        _previews?.ClearFailures();
        _ = _store.RefreshAsync(explicit_: true);
    }

    private void ShowNotice(string text, TimeSpan seconds) => ShowNotice(text, seconds, null);

    private void ShowNotice(string text, TimeSpan seconds, (string Title, Action Act)? action)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 460 });
        if (action is { } a)
        {
            var b = new Button { Content = a.Title, Style = (Style)Application.Current.Resources["QuietButtonStyle"], Foreground = Look.Brush("AccentTextFillColorPrimaryBrush") };
            b.Click += (_, _) => { a.Act(); HideNotice(); };
            row.Children.Add(b);
        }
        else _notice.Padding = new Thickness(16, 8, 16, 8);
        _notice.Child = row;
        _notice.Visibility = Visibility.Visible;
        AutomationProperties.SetName(_notice, text);
        AutomationProperties.SetLiveSetting(_notice, AutomationLiveSetting.Polite);
        _noticeTimer ??= DispatcherQueue.CreateTimer();
        _noticeTimer.Stop();
        _noticeTimer.Interval = seconds;
        _noticeTimer.IsRepeating = false;
        _noticeTimer.Tick -= NoticeTick;
        _noticeTimer.Tick += NoticeTick;
        _noticeTimer.Start();
    }

    private void NoticeTick(DispatcherQueueTimer timer, object _) => HideNotice();

    private void HideNotice()
    {
        _noticeTimer?.Stop();
        _notice.Visibility = Visibility.Collapsed;
        _notice.Padding = new Thickness(16, 8, 10, 8);
    }
}
