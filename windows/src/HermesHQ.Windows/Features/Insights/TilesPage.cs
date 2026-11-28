using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Chat;
using Hermes.Core.Composer;
using Hermes.Core.Insights;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Settings;
using HermesHQ.Features.Attachments;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Composer;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace HermesHQ.Features.Insights;

/// Tools › Tiles (App/Pages/Artifacts/ArtifactsViewController.swift with `pinnedOnly`, PinnedArtifacts.swift,
/// LiveTiles.swift, TileUpdates.swift, TilesV2Actions.swift): the pages, pictures and files pinned from the bots' chats,
/// as a dashboard. Supports Small, Medium, Tall, Banner, Large, Extra Large tiles; page icons; Empty Tiles with New Tile
/// + Open Artifacts (hiding bar filter/search/count/View As when empty); Edit mode batch controls + blue corner resize
/// handles; Tile Activity dialog; Change… / Duplicate…; writable Versions Roll Back / Restore; fast in-place WebView2
/// theme switching (`__hqApplyTheme`) + 4-view warm pool; live-tile busy/1s throttle guards; PNG image export; persisted
/// hidden tile makers with inline making cards, changing veils, changed rings, replyGrace, failure recovery, upgraded
/// Updates menu (Keep Updated, Fix with Bot, View Job/Last Run, Model override), drag-reorder/drop page pills, and Ctrl+1..9.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class TilesPage : InsightsPage, IKeyRefreshing
{
    public const int WarmLimit = 4;
    private const string PageDragPrefix = "hq-page:";
    private const string TileDragPrefix = "hq-tile:";

    private static readonly IKeyValueStore Prefs = new JsonFileStore(Path.Combine(AppPaths.Root, "tiles-view.json"));
    private static readonly IKeyValueStore PendingPrefs = new JsonFileStore(Path.Combine(AppPaths.Root, "tile-pending-makers.json"));
    private static readonly IKeyValueStore TileModelPrefs = new JsonFileStore(Path.Combine(AppPaths.Root, "tile-models.json"));
    private static readonly Dictionary<string, (TilePinStore Pins, TileHidden Hidden, TileSync Sync, TileUpdates Updates)> Accounts = [];
    private static readonly List<ActiveTileMaker> ActiveMakers = [];

    private TilePinStore? _pins;
    private TileHidden? _hidden;
    private TileSync? _sync;
    private TileUpdates? _updates;
    private TilePictures? _pictures;
    private HermesClient? _client;
    private string? _warmAccount;
    private IReadOnlyList<Bot> _bots = [];
    private string _scope = "all";
    private string _query = "";
    private bool _editing;
    private readonly HashSet<string> _selected = [];
    private readonly HashSet<string> _ringedPins = new(StringComparer.Ordinal);
    private readonly Dictionary<string, TileCell> _cells = [];
    private readonly TileLiveGuard _liveGuard = new();
    private readonly Grid _header;
    private readonly TextBlock _count;
    private readonly StackPanel _headerButtons;
    private readonly StackPanel _band;
    private readonly StackPanel _makingBar;
    private readonly ScrollViewer _scroll;
    private readonly Canvas _canvas;
    private readonly Grid _root;
    private readonly Grid _overlay;
    private readonly Border _toast;
    private readonly TextBox _search;
    private readonly Button _filter;
    private readonly Button _newTileBar;
    private readonly Button _activityBar;
    private TileViewer? _viewer;
    private CancellationTokenSource? _life;

    public const double GridInset = 20, GridSpacing = 12, NameHeight = 22;

    private static TilesView View
    {
        get => Prefs.Get("view") switch { "cards" => TilesView.Cards, "list" => TilesView.List, _ => TilesView.Grid };
        set => Prefs.Set("view", value.ToString().ToLowerInvariant());
    }

    /// Grid's names under the tiles: on by default on the Mac (and so here).
    private static bool ShowsNames
    {
        get => Prefs.Get("names") != "off";
        set => Prefs.Set("names", value ? null : "off");
    }

    public TilesPage()
    {
        _search = new TextBox { PlaceholderText = TileWords.SearchPlaceholder, Width = 200, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(_search, TileWords.SearchPlaceholder);
        AutomationProperties.SetAutomationId(_search, "pins.search");
        _search.TextChanged += (_, _) => { _query = _search.Text.Trim(); Render(); };
        _count = new TextBlock { FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Kit.Brush("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        _headerButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right };
        _header = new Grid { Padding = new Thickness(GridInset, 0, 12, 4), MinHeight = 32, Children = { _count, _headerButtons } };
        _band = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Padding = new Thickness(GridInset, 2, GridInset, 8), Visibility = Visibility.Collapsed };
        AutomationProperties.SetName(_band, "Pages");
        _makingBar = new StackPanel { Spacing = 6, Padding = new Thickness(GridInset, 2, GridInset, 8), Visibility = Visibility.Collapsed };
        AutomationProperties.SetAutomationId(_makingBar, "tiles.making.list");
        _canvas = new Canvas();
        _scroll = new ScrollViewer { Content = _canvas, HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        AutomationProperties.SetAutomationId(_scroll, "pinned.list");
        _scroll.SizeChanged += (_, _) => Layout();
        _root = new Grid();
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.Children.Add(_header);
        Grid.SetRow(_band, 1);
        _root.Children.Add(_band);
        Grid.SetRow(_makingBar, 2);
        _root.Children.Add(_makingBar);
        Grid.SetRow(_scroll, 3);
        _root.Children.Add(_scroll);
        _toast = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 24),
            Padding = new Thickness(16, 8, 10, 8), CornerRadius = new CornerRadius(18), Visibility = Visibility.Collapsed,
            Background = Kit.Brush("AcrylicInAppFillColorDefaultBrush"), BorderBrush = Kit.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
        };
        _overlay = new Grid { Children = { _root, _toast } };

        _newTileBar = Kit.BarButton("\uE710", TileWords.NewTile, () => _ = ShowNewTileAsync());
        AutomationProperties.SetAutomationId(_newTileBar, "tile.new.bar");
        _activityBar = Kit.BarButton("\uE823", TileWords.TileActivity, () => _ = ShowActivityAsync());
        AutomationProperties.SetAutomationId(_activityBar, "tile.activity");
        _filter = Kit.BarButton("", TileWords.AllBots, () => { });
        AutomationProperties.SetAutomationId(_filter, "pins.filter");

        BarActions.Children.Add(_newTileBar);
        BarActions.Children.Add(_activityBar);
        BarActions.Children.Add(_filter);
        BarActions.Children.Add(_search);

        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        var newAccel = new KeyboardAccelerator { Key = VirtualKey.N, Modifiers = VirtualKeyModifiers.Control };
        newAccel.Invoked += (s, e) => { if (!ReadOnlyGateway) { e.Handled = true; _ = ShowNewTileAsync(); } };
        KeyboardAccelerators.Add(newAccel);

        // [tiles-v2] Ctrl+1..9 switches Dashboard pages when multiple pages exist.
        for (var i = 0; i < 9; i++)
        {
            var pageIndex = i;
            var accel = new KeyboardAccelerator { Key = VirtualKey.Number1 + i, Modifiers = VirtualKeyModifiers.Control };
            accel.Invoked += (_, e) =>
            {
                if (!ShowsPages || _pins == null || _pins.Pages.Count <= 1 || pageIndex >= _pins.Pages.Count) return;
                e.Handled = true;
                SwitchToPage(_pins.Pages[pageIndex].Id);
            };
            KeyboardAccelerators.Add(accel);
        }

        // [28b14acf7] Update existing live WebView2 tiles in place instead of destroying and recreating cells.
        ActualThemeChanged += (_, _) => ApplyThemeToCells();
    }

    private void OnThemeServiceChanged() => OnUi(ApplyThemeToCells);

    private void ApplyThemeToCells()
    {
        if (AppShutdown.Stopping) return;
        var dark = ActualTheme == ElementTheme.Dark;
        foreach (var cell in _cells.Values)
            _ = cell.ApplyThemeAsync(dark);
    }

    private void ClearCells()
    {
        foreach (var cell in _cells.Values) cell.CloseWeb();
        _cells.Clear();
        _canvas.Children.Clear();
    }

    /// [tiles-v2] Keeps up to `WarmLimit` (4) recently shown WebView2 tiles warm across tab/page switches,
    /// closing older WebView2 instances cleanly.
    private void TrimWarmPool(HashSet<string>? keepIds = null)
    {
        var ranked = _cells
            .Where(kv => keepIds == null || !keepIds.Contains(kv.Key))
            .OrderByDescending(kv => kv.Value.HasWeb ? 1 : 0)
            .ThenByDescending(kv => kv.Value.ShownAt)
            .Select(kv => kv.Key)
            .ToList();
        var allowedWarm = keepIds == null ? WarmLimit : Math.Max(0, WarmLimit - keepIds.Count);
        foreach (var id in ranked.Skip(allowedWarm))
        {
            if (_cells.Remove(id, out var cell))
            {
                cell.CloseWeb();
                _canvas.Children.Remove(cell);
            }
        }
    }

    public void KeyRefresh() => RefreshAllTiles();

    private void RefreshAllTiles()
    {
        if (_pins == null) return;
        foreach (var pin in _pins.Pins.Where(p => p.IsPage)) Reread(pin.Id);
        SyncSoon();
        Toast("Refreshed Tiles");
    }

    /// The account's pins, hidden tiles, sync and page updates, made once per account.
    private static (TilePinStore Pins, TileHidden Hidden, TileSync Sync, TileUpdates Updates) Ensure(HermesClient client)
    {
        var account = client.AccountId;
        if (Accounts.TryGetValue(account, out var a)) return a;
        var dir = Path.Combine(AppPaths.Root, "pages");
        var pins = new TilePinStore(TilePinStore.FileFor(Path.Combine(dir, "pins"), account));
        var hidden = new TileHidden(TilePinStore.FileFor(Path.Combine(dir, "hidden"), account));
        var sync = new TileSync((m, p, t, ct) => AppState.Client is { } c ? c.Rpc.RequestAsync(m, p, t, ct)
                : throw new GatewayException("offline", "Not connected to the gateway."),
            pins, hidden, TilePinStore.FileFor(Path.Combine(dir, "sync"), account));
        a = (pins, hidden, sync, new TileUpdates(client.Session));
        Accounts[account] = a;
        return a;
    }

    /// [page-cards] The account's pins, shared with a chat's page cards (their Pin as Tile / Unpin and pin badge).
    internal static TilePinStore PinsFor(HermesClient client) => Ensure(client).Pins;

    // ------------------------------------------------------------------ lifecycle

    protected override void Shown()
    {
        _life?.Cancel();
        _life = new CancellationTokenSource();
        _client = Client;
        ThemeService.Changed -= OnThemeServiceChanged;
        ThemeService.Changed += OnThemeServiceChanged;
        if (_client == null)
        {
            ClearCells();
            _warmAccount = null;
            _filter.Visibility = _search.Visibility = _newTileBar.Visibility = _activityBar.Visibility = Visibility.Collapsed;
            SetBody(Kit.Empty("", TileWords.NoTilesYet, TileWords.HowTo));
            return;
        }
        var account = _client.AccountId;
        if (_warmAccount != account)
        {
            ClearCells();
            _warmAccount = account;
        }
        (_pins, _hidden, _sync, _updates) = Ensure(_client);
        _pictures = TilePictures.Of(account);
        _pins.Changed += OnPinsChanged;
        _hidden.Changed += OnPinsChanged;
        _bots = _client.Bots ?? [];
        _scope = Prefs.Get("scope." + account) is { } s && (s == "all" || _bots.Any(b => b.Name == s)) ? s : "all";
        BuildFilter();
        SetBody(_overlay);
        foreach (var remembered in TileChats.ChatIds(account, PendingPrefs)) TileChats.RememberSession(remembered);
        RestorePendingMakers();
        Render();
        var ct = _life.Token;
        _ = LoadBotsAsync(ct);
        _ = SyncLoopAsync(ct);
        _ = WatchJobsAsync(ct);
        _ = LiveLoopAsync(ct);
    }

    protected override void Hidden()
    {
        _life?.Cancel();
        _life = null;
        ThemeService.Changed -= OnThemeServiceChanged;
        _toastTimer?.Stop();
        _toastTimer = null;
        if (_pins != null) _pins.Changed -= OnPinsChanged;
        if (_hidden != null) _hidden.Changed -= OnPinsChanged;
        _updates?.CancelAllPolls();
        _viewer?.Close();
        UiTree.DeactivateProgressRings(_makingBar);
        TrimWarmPool();
        _selected.Clear();
    }

    private void OnPinsChanged() => OnUi(Render);

    private async Task LoadBotsAsync(CancellationToken ct)
    {
        if (_client == null) return;
        try
        {
            _bots = await _client.BotsAsync(ct);
            OnUi(() =>
            {
                BuildFilter();
                RestorePendingMakers();
                Render();
            });
        }
        catch (Exception e) when (e is GatewayException or OperationCanceledException) { }
    }

    /// The gateway's copy taken in now, and every minute while the page shows; a change made here goes up at once.
    private async Task SyncLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { if (_sync != null) await _sync.SyncAsync(ct); }
            catch (Exception e) when (e is GatewayException or OperationCanceledException) { }
            try { await Task.Delay(TimeSpan.FromSeconds(60), ct); } catch (OperationCanceledException) { return; }
        }
    }

    private void SyncSoon()
    {
        var sync = _sync;
        if (sync == null) return;
        _ = Task.Run(async () =>
        {
            try { await sync.SyncAsync(); }
            catch (Exception e) when (e is GatewayException or OperationCanceledException) { }
        });
    }

    /// The tiles' jobs read each minute (each 15 s while one runs), their marks kept current, and a tile whose job has
    /// just run drawn again at once.
    private async Task WatchJobsAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _pins != null && _updates != null)
        {
            var pages = _pins.Pins.Where(p => p.IsPage).ToList();
            if (pages.Count > 0)
            {
                try
                {
                    var (marks, ran) = await _updates.RefreshAsync(pages, DateTimeOffset.Now, ct);
                    OnUi(() =>
                    {
                        foreach (var id in marks) if (_cells.TryGetValue(id, out var c)) c.SetHealth(Health(id));
                        foreach (var id in ran) Reread(id);
                    });
                }
                catch (Exception e) when (e is GatewayException or OperationCanceledException) { }
            }
            try { await Task.Delay(_updates.AnyUpdating ? TimeSpan.FromSeconds(15) : TimeSpan.FromSeconds(60), ct); }
            catch (OperationCanceledException) { return; }
        }
    }

    /// A live tile's page read again when it asks (`hq-tile-refresh`), checked every 10 s.
    private async Task LiveLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(10), ct); } catch (OperationCanceledException) { return; }
            OnUi(() =>
            {
                if (_pictures == null) return;
                foreach (var id in _cells.Keys.ToList())
                {
                    if (_pictures.Get(id) is { Head.RefreshSeconds: { } every } e && DateTimeOffset.UtcNow - e.ReadAt >= TimeSpan.FromSeconds(every))
                        Reread(id);
                }
            });
        }
    }

    private void Reread(string id)
    {
        if (_client == null || _pins == null || _pictures == null) return;
        var pin = _pins.Pins.FirstOrDefault(p => p.Id == id);
        if (pin == null) return;
        _ = ReadThen(pin, fresh: true);
        if (_viewer?.Pin.Id == id) _ = _viewer.ReloadAsync();
    }

    private async Task ReadThen(TilePin pin, bool fresh)
    {
        if (_client == null || _pictures == null) return;
        await _pictures.ReadAsync(_client.Session, pin, fresh);
        var entry = _pictures.Get(pin.Id);
        if (entry?.Head is { } head && _pins != null) _pins.NotePage(pin.Id, head);
        if (entry is { Gone: true } && pin.IsPage) _updates?.MarkGone(pin.Id);
        if (!_cells.TryGetValue(pin.Id, out var cell)) return;
        if (cell.HasWeb && entry?.Html is { } html) cell.Reload(html);
        else cell.ShowPicture(entry, ShowsNames, ActualTheme == ElementTheme.Dark, allowWeb: true);
        cell.SetHealth(Health(pin.Id));
    }

    private TileJobs.Health Health(string id)
    {
        if (_pictures?.Get(id) is { Gone: true }) return new(TileJobs.HealthKind.Failed, TileWords.GoneWords);
        return _updates?.Health(id) ?? TileJobs.Health.None;
    }

    // ------------------------------------------------------------------ the bar's filter

    private void BuildFilter()
    {
        var flyout = new MenuFlyout();
        void Add(string id, string title)
        {
            var item = new RadioMenuFlyoutItem { Text = title, GroupName = "scope", IsChecked = _scope == id };
            item.Click += (_, _) =>
            {
                _scope = id;
                if (_client != null) Prefs.Set("scope." + _client.AccountId, id);
                Render();
                BuildFilter();
            };
            flyout.Items.Add(item);
        }
        Add("all", TileWords.AllBots);
        foreach (var b in _bots.OrderBy(b => b.Name == "default" ? 0 : 1)) Add(b.Name, b.DisplayName);
        _filter.Flyout = flyout;
        var label = _scope == "all" ? TileWords.AllBots : BotName(_scope);
        ToolTipService.SetToolTip(_filter, label);
        AutomationProperties.SetName(_filter, label);
    }

    private string BotName(string profile) =>
        _bots.FirstOrDefault(b => b.Name == profile)?.DisplayName ?? (profile == "default" ? "Hermes" : ModelNames.TitleCase(profile.Replace('-', ' ')));

    // ------------------------------------------------------------------ what shows

    private bool ShowsPages => _scope == "all" && _query.Length == 0;

    private List<ActiveTileMaker> AccountMakers() =>
        _client == null ? [] : ActiveMakers.Where(m => m.AccountId == _client.AccountId && m.Watching).ToList();

    private ActiveTileMaker? WorkingMakerFor(string pinId) =>
        _client == null ? null : ActiveMakers.FirstOrDefault(m => m.AccountId == _client.AccountId && m.Watching && m.PinId == pinId);

    private bool IsWorkingOn(string pinId) => WorkingMakerFor(pinId) != null;

    private static string? MakersHeaderSuffix(IReadOnlyList<ActiveTileMaker> makers)
    {
        if (makers.Count == 0) return null;
        var making = makers.Count(m => m.PinId == null);
        var changing = makers.Count(m => m.PinId != null);
        if (making > 0 && changing > 0) return $"Making {making}, changing {changing}…";
        if (making > 0) return making == 1 ? "Making a tile…" : $"Making {making} tiles…";
        return changing == 1 ? "Changing a tile…" : $"Changing {changing} tiles…";
    }

    private void SwitchToPage(string pageId)
    {
        if (_pins == null || _pins.CurrentPage == pageId) return;
        _pins.CurrentPage = pageId;
        Render();
    }

    /// The tiles on screen: not removed, the bot picked, the page shown, the search's.
    private List<TilePin> Visible()
    {
        if (_pins == null || _hidden == null) return [];
        IEnumerable<TilePin> pins = _hidden.Visible(_pins.Pins);
        if (_scope != "all") pins = pins.Where(p => p.Profile == _scope);
        if (ShowsPages) pins = pins.Where(p => _pins.PageId(p) == _pins.CurrentPage);
        if (_query.Length > 0)
            pins = pins.Where(p => _pins.Name(p).Contains(_query, StringComparison.CurrentCultureIgnoreCase)
                || p.Label.Contains(_query, StringComparison.CurrentCultureIgnoreCase)
                || p.SessionTitle.Contains(_query, StringComparison.CurrentCultureIgnoreCase));
        return pins.ToList();
    }

    private string Subtitle(TilePin pin)
    {
        var bot = BotName(pin.Profile);
        if (_scope != "all" && pin.SessionTitle.Length > 0) return pin.SessionTitle;
        return pin.SessionTitle.Length == 0 ? bot : $"{bot} · {pin.SessionTitle}";
    }

    private void RenderMakingBar(IReadOnlyList<ActiveTileMaker> makers)
    {
        UiTree.DeactivateProgressRings(_makingBar);
        _makingBar.Children.Clear();
        if (makers.Count == 0)
        {
            _makingBar.Visibility = Visibility.Collapsed;
            return;
        }
        _makingBar.Visibility = Visibility.Visible;
        foreach (var maker in makers)
        {
            var m = maker;
            var card = TileMakingCard.Create(
                m,
                openChat: () => Navigator.Go(new ChatDestination(m.Bot.Name, m.SessionId, m.DisplayTitle)),
                stop: () => m.CancelAction?.Invoke());
            _makingBar.Children.Add(card);
        }
    }

    private void Render()
    {
        if (_pins == null || _client == null) return;
        var shown = Visible();
        var accountMakers = AccountMakers();
        RenderMakingBar(accountMakers);

        // [tiles-v2] Hide filter, Search Tiles, "0 Items", and View As when Tiles is empty (with no active query/filter/makers),
        // matching Mac build 1264+ ArtifactsViewController empty chrome.
        var emptyNoControls = shown.Count == 0 && _query.Length == 0 && _scope == "all" && accountMakers.Count == 0;
        _filter.Visibility = !emptyNoControls && _bots.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        _search.Visibility = emptyNoControls ? Visibility.Collapsed : Visibility.Visible;
        _newTileBar.Visibility = !emptyNoControls && !ReadOnlyGateway ? Visibility.Visible : Visibility.Collapsed;
        _activityBar.Visibility = !emptyNoControls || accountMakers.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _header.Visibility = emptyNoControls && !_editing ? Visibility.Collapsed : Visibility.Visible;

        if (shown.Count == 0 && _editing)
        {
            _editing = false;
            _selected.Clear();
            _header.Visibility = emptyNoControls ? Visibility.Collapsed : Visibility.Visible;
        }

        if (_editing && _selected.Count > 0)
        {
            _count.Text = $"{_selected.Count} Selected";
        }
        else
        {
            var baseCount = TileWords.ItemCount(shown.Count);
            var makingWords = MakersHeaderSuffix(accountMakers);
            _count.Text = makingWords == null ? baseCount : $"{baseCount} · {makingWords}";
        }
        BuildHeaderButtons(shown);
        BuildBand();
        if (shown.Count == 0)
        {
            _canvas.Children.Clear();
            TrimWarmPool();
            _scroll.Content = EmptyState();
            return;
        }
        if (!ReferenceEquals(_scroll.Content, _canvas)) _scroll.Content = _canvas;
        var view = View;
        var ids = shown.Select(p => p.Id).ToHashSet(StringComparer.Ordinal);
        TrimWarmPool(ids);
        _selected.IntersectWith(ids);
        _canvas.Children.Clear();
        foreach (var pin in shown)
        {
            if (!_cells.TryGetValue(pin.Id, out var cell) || (string?)cell.Tag != Key(view))
            {
                if (_cells.TryGetValue(pin.Id, out var stale)) stale.CloseWeb();
                cell = MakeCell(pin, view);
                _cells[pin.Id] = cell;
            }
            cell.ShownAt = DateTimeOffset.UtcNow;
            cell.Update(pin);
            cell.SetName(_pins.Name(pin));
            cell.SetSubtitle(Subtitle(pin));
            cell.SetEditing(_editing);
            cell.SetSelected(_selected.Contains(pin.Id));
            cell.SetHealth(Health(pin.Id));
            cell.SetWorking(WorkingMakerFor(pin.Id)?.TileWords);
            cell.SetRinged(_ringedPins.Contains(pin.Id));
            _canvas.Children.Add(cell);
        }
        Layout();
    }

    private static string Key(TilesView view) => view + (ShowsNames ? "+names" : "");

    private TileCell MakeCell(TilePin pin, TilesView view)
    {
        var cell = new TileCell(pin, view, ShowsNames, Subtitle(pin)) { Tag = Key(view) };
        cell.Activated += c => Open(c.Pin);
        cell.UnpinRequested += c => Unpin(c.Pin);
        cell.ResizeRequested += (c, size) => { _pins?.SetSize(size, c.Pin.Id); SyncSoon(); };
        cell.SelectionToggled += c =>
        {
            if (!_selected.Add(c.Pin.Id)) _selected.Remove(c.Pin.Id);
            Render();
        };
        cell.WebMessage += (c, m, web) => OnWebMessage(c.Pin, m, web);
        var flyout = new MenuFlyout();
        flyout.Opening += (_, _) => FillMenu(flyout, cell.Pin);
        cell.ContextFlyout = flyout;
        // Edit Tiles (or dragging onto a page pill): drag a tile onto another tile or a page pill.
        cell.CanDrag = true;
        cell.AllowDrop = true;
        cell.DragStarting += (_, e) =>
        {
            if (!_editing && (_pins == null || _pins.Pages.Count < 2)) { e.Cancel = true; return; }
            e.Data.SetText(TileDragPrefix + cell.Pin.Id);
            e.Data.RequestedOperation = DataPackageOperation.Move;
        };
        cell.DragOver += (_, e) => { if (_editing) e.AcceptedOperation = DataPackageOperation.Move; };
        cell.Drop += async (_, e) =>
        {
            if (!_editing) return;
            bool hasText;
            try { hasText = e.DataView.Contains(StandardDataFormats.Text); }
            catch (Exception) { return; }
            if (!hasText) return;
            var deferral = e.GetDeferral();
            try
            {
                var raw = await e.DataView.GetTextAsync();
                if (raw.StartsWith(PageDragPrefix, StringComparison.Ordinal)) return;
                var id = raw.StartsWith(TileDragPrefix, StringComparison.Ordinal) ? raw[TileDragPrefix.Length..] : raw;
                if (id != cell.Pin.Id) { _pins?.Move(id, cell.Pin.Id); SyncSoon(); }
            }
            catch (Exception ex) { AppLog.Note("tiles", $"drop failed: {ex.GetType().Name}"); }
            finally { deferral.Complete(); }
        };
        var entry = _pictures?.Get(pin.Id);
        cell.ShowPicture(entry, ShowsNames, ActualTheme == ElementTheme.Dark, allowWeb: true);
        if (entry == null || (entry.Html == null && entry.Image == null && !entry.Gone && entry.Failure == null)) _ = ReadThen(pin, fresh: false);
        return cell;
    }

    /// Places the tiles: Grid packs them in square cells (Small, Medium, Tall, Banner, Large, Extra Large);
    /// Cards are 320 wide columns, pictures 230 tall; List is rows.
    private void Layout()
    {
        var width = _scroll.ActualWidth;
        if (width <= 0 || !ReferenceEquals(_scroll.Content, _canvas)) return;
        var cells = _canvas.Children.OfType<TileCell>().ToList();
        double height;
        switch (View)
        {
            case TilesView.Grid:
            {
                var (columns, side) = TileGridPacking.Metrics(width - 2 * GridInset, GridSpacing);
                var name = ShowsNames ? NameHeight : 0;
                var rowHeight = side + name;
                var (placed, rows) = TileGridPacking.Place(cells.Select(c => c.Pin.TileSize.Span()), columns);
                for (var i = 0; i < cells.Count; i++)
                {
                    var p = placed[i];
                    var c = cells[i];
                    c.SetGridMetrics(columns, side, GridSpacing);
                    Canvas.SetLeft(c, GridInset + p.Column * (side + GridSpacing));
                    Canvas.SetTop(c, 8 + p.Row * (rowHeight + GridSpacing));
                    c.Width = p.Columns * side + (p.Columns - 1) * GridSpacing;
                    c.Height = p.Rows * rowHeight + (p.Rows - 1) * GridSpacing;
                }
                height = 8 + rows * rowHeight + Math.Max(0, rows - 1) * GridSpacing + 16;
                break;
            }
            case TilesView.Cards:
            {
                var columns = Math.Max(1, (int)((width - 32) / 320));
                var cardWidth = (width - 20) / columns - 12;
                var cardHeight = (width >= 600 ? 230 : 210) + 56;
                for (var i = 0; i < cells.Count; i++)
                {
                    var c = cells[i];
                    Canvas.SetLeft(c, 16 + (i % columns) * (cardWidth + 12));
                    Canvas.SetTop(c, 8 + (i / columns) * (cardHeight + 12));
                    c.Width = cardWidth;
                    c.Height = cardHeight;
                }
                height = 8 + Math.Ceiling(cells.Count / (double)columns) * (cardHeight + 12) + 16;
                break;
            }
            default:
            {
                for (var i = 0; i < cells.Count; i++)
                {
                    var c = cells[i];
                    Canvas.SetLeft(c, 0);
                    Canvas.SetTop(c, i * 57);
                    c.Width = width;
                    c.Height = 56;
                }
                height = cells.Count * 57 + 16;
                break;
            }
        }
        _canvas.Width = width;
        _canvas.Height = height;
    }

    // ------------------------------------------------------------------ the header: count, View As, Edit Tiles batch controls

    private void BuildHeaderButtons(List<TilePin> shown)
    {
        _headerButtons.Children.Clear();
        if (_editing)
        {
            var allSelected = shown.Count > 0 && _selected.Count == shown.Count;
            var selectToggle = new Button
            {
                Content = allSelected ? TileWords.ClearSelection : TileWords.SelectAll,
                FontSize = 12,
                Padding = new Thickness(10, 4, 10, 5),
            };
            AutomationProperties.SetAutomationId(selectToggle, "tiles.batch.select");
            selectToggle.Click += (_, _) =>
            {
                if (allSelected) _selected.Clear();
                else foreach (var p in shown) _selected.Add(p.Id);
                Render();
            };
            _headerButtons.Children.Add(selectToggle);

            if (_selected.Count > 0 && _pins != null)
            {
                var sizeBtn = new DropDownButton { Content = TileWords.Size, FontSize = 12, Padding = new Thickness(10, 4, 8, 5) };
                AutomationProperties.SetAutomationId(sizeBtn, "tiles.batch.size");
                var sizeMenu = new MenuFlyout();
                foreach (var sz in TileSizes.All)
                {
                    var s = sz;
                    var item = new MenuFlyoutItem { Text = s.Title() };
                    item.Click += (_, _) =>
                    {
                        foreach (var id in _selected.ToList()) _pins.SetSize(s, id);
                        SyncSoon();
                    };
                    sizeMenu.Items.Add(item);
                }
                sizeBtn.Flyout = sizeMenu;
                _headerButtons.Children.Add(sizeBtn);

                if (_pins.Pages.Count > 1)
                {
                    var moveBtn = new DropDownButton { Content = TileWords.MoveToPage, FontSize = 12, Padding = new Thickness(10, 4, 8, 5) };
                    AutomationProperties.SetAutomationId(moveBtn, "tiles.batch.move");
                    var moveMenu = new MenuFlyout();
                    foreach (var pg in _pins.Pages)
                    {
                        var page = pg;
                        var item = new MenuFlyoutItem { Text = page.Name };
                        item.Click += (_, _) =>
                        {
                            foreach (var id in _selected.ToList()) _pins.SetPage(page.Id, id);
                            _selected.Clear();
                            SyncSoon();
                            Toast(TileWords.MovedTo(page.Name));
                        };
                        moveMenu.Items.Add(item);
                    }
                    moveBtn.Flyout = moveMenu;
                    _headerButtons.Children.Add(moveBtn);
                }

                var unpinSelected = new Button
                {
                    Content = $"{TileWords.Unpin} ({_selected.Count})",
                    FontSize = 12,
                    Padding = new Thickness(10, 4, 10, 5),
                };
                AutomationProperties.SetAutomationId(unpinSelected, "tiles.batch.unpin");
                unpinSelected.Click += (_, _) =>
                {
                    var count = _selected.Count;
                    foreach (var id in _selected.ToList()) _pins.Unpin(id);
                    _selected.Clear();
                    SyncSoon();
                    Toast($"Unpinned {count} {(count == 1 ? "tile" : "tiles")}");
                };
                _headerButtons.Children.Add(unpinSelected);
            }

            if (!ReadOnlyGateway)
            {
                var batchMenuBtn = new DropDownButton { Content = TileWords.Updates, FontSize = 12, Padding = new Thickness(10, 4, 8, 5) };
                AutomationProperties.SetAutomationId(batchMenuBtn, "tiles.batch.updates");
                var batchMenu = new MenuFlyout();
                Item(batchMenu, TileWords.UpdateAllNow, "\uE72C", () => _ = UpdateAllPageTilesAsync());
                Item(batchMenu, TileWords.PauseAllUpdates, "\uE769", () => _ = SetAllPageTilesPausedAsync(true));
                Item(batchMenu, TileWords.ResumeAllUpdates, "\uE768", () => _ = SetAllPageTilesPausedAsync(false));
                batchMenuBtn.Flyout = batchMenu;
                _headerButtons.Children.Add(batchMenuBtn);
            }

            var done = new Button { Content = TileWords.Done, Style = Kit.Style("AccentButtonStyle"), FontWeight = FontWeights.SemiBold };
            AutomationProperties.SetAutomationId(done, "tiles.edit.done");
            done.Click += (_, _) => SetEditing(false);
            _headerButtons.Children.Add(done);
            return;
        }

        var view = Kit.BarButton(View switch { TilesView.Grid => "", TilesView.Cards => "", _ => "" }, TileWords.ViewAs, () => { });
        AutomationProperties.SetAutomationId(view, "pins.view");
        var menu = new MenuFlyout();
        menu.Items.Add(new MenuFlyoutItem { Text = TileWords.ViewAs, IsEnabled = false });
        foreach (var v in new[] { TilesView.Grid, TilesView.Cards, TilesView.List })
        {
            var item = new RadioMenuFlyoutItem { Text = TileWords.ViewTitle(v), GroupName = "view", IsChecked = View == v };
            AutomationProperties.SetAutomationId(item, "pins.view." + v.ToString().ToLowerInvariant());
            item.Click += (_, _) => { View = v; Render(); };
            menu.Items.Add(item);
        }
        if (View == TilesView.Grid)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            var names = new ToggleMenuFlyoutItem { Text = TileWords.ShowNames, IsChecked = ShowsNames };
            names.Click += (_, _) => { ShowsNames = !ShowsNames; Render(); };
            menu.Items.Add(names);
            var edit = new MenuFlyoutItem { Text = TileWords.EditTiles, Icon = new FontIcon { Glyph = "" } };
            edit.Click += (_, _) => SetEditing(true);
            menu.Items.Add(edit);
        }
        if (!ReadOnlyGateway)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            Item(menu, TileWords.UpdateAllNow, "\uE72C", () => _ = UpdateAllPageTilesAsync());
            Item(menu, TileWords.PauseAllUpdates, "\uE769", () => _ = SetAllPageTilesPausedAsync(true));
            Item(menu, TileWords.ResumeAllUpdates, "\uE768", () => _ = SetAllPageTilesPausedAsync(false));
        }
        if (ShowsPages)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            var page = new MenuFlyoutItem { Text = TileWords.NewPage, Icon = new FontIcon { Glyph = "" } };
            page.Click += async (_, _) =>
            {
                if (await AskName(TileWords.NewPageTitle, "", TileWords.Add) is { } name) { _pins?.AddPage(name); SyncSoon(); }
            };
            menu.Items.Add(page);
        }
        view.Flyout = menu;
        _headerButtons.Children.Add(view);
    }

    private void SetEditing(bool on)
    {
        if (_editing == on) return;
        _editing = on;
        if (!on) _selected.Clear();
        Render();
    }

    /// The Tiles' pages as a row of pills (with optional page icon, drag-to-reorder, and drop-tile-onto-page-pill)
    /// under the header (DashboardPagesBar).
    private void BuildBand()
    {
        _band.Children.Clear();
        if (_pins == null || !ShowsPages || _pins.Pages.Count < 2) { _band.Visibility = Visibility.Collapsed; return; }
        var pins = _pins;
        _band.Visibility = Visibility.Visible;
        var pages = pins.Pages;
        for (var i = 0; i < pages.Count; i++)
        {
            var page = pages[i];
            var index = i;
            UIElement pillContent;
            if (!string.IsNullOrEmpty(page.Symbol))
            {
                pillContent = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 6,
                    Children =
                    {
                        new FontIcon { Glyph = TileSymbolGlyphs.Glyph(page.Symbol), FontSize = 12, VerticalAlignment = VerticalAlignment.Center },
                        new TextBlock { Text = page.Name, VerticalAlignment = VerticalAlignment.Center },
                    },
                };
            }
            else
            {
                pillContent = new TextBlock { Text = page.Name };
            }
            var pill = new ToggleButton
            {
                Content = pillContent,
                IsChecked = page.Id == pins.CurrentPage,
                CornerRadius = new CornerRadius(14),
                Padding = new Thickness(12, 4, 12, 5),
                AllowDrop = true,
                CanDrag = page.Id != TilePage.MainId,
            };
            AutomationProperties.SetName(pill, page.Name);
            AutomationProperties.SetAutomationId(pill, "dashboard.page." + page.Id);
            pill.Click += (_, _) => SwitchToPage(page.Id);
            pill.ContextFlyout = PageMenu(pins, page, index, pages.Count);

            if (page.Id != TilePage.MainId)
            {
                pill.DragStarting += (_, e) =>
                {
                    e.Data.SetText(PageDragPrefix + page.Id);
                    e.Data.RequestedOperation = DataPackageOperation.Move;
                };
            }
            pill.DragOver += (_, e) =>
            {
                e.AcceptedOperation = DataPackageOperation.Move;
                pill.BorderBrush = Kit.Brush("AccentFillColorDefaultBrush");
                pill.BorderThickness = new Thickness(2);
            };
            pill.DragLeave += (_, _) =>
            {
                pill.ClearValue(Control.BorderBrushProperty);
                pill.ClearValue(Control.BorderThicknessProperty);
            };
            pill.Drop += async (_, e) =>
            {
                pill.ClearValue(Control.BorderBrushProperty);
                pill.ClearValue(Control.BorderThicknessProperty);
                bool hasText;
                try { hasText = e.DataView.Contains(StandardDataFormats.Text); }
                catch (Exception) { return; }
                if (!hasText) return;
                var deferral = e.GetDeferral();
                try
                {
                    var raw = await e.DataView.GetTextAsync();
                    if (raw.StartsWith(PageDragPrefix, StringComparison.Ordinal))
                    {
                        var sourceId = raw[PageDragPrefix.Length..];
                        if (sourceId != page.Id)
                        {
                            pins.ReorderPage(sourceId, page.Id);
                            SyncSoon();
                        }
                    }
                    else
                    {
                        var tileId = raw.StartsWith(TileDragPrefix, StringComparison.Ordinal) ? raw[TileDragPrefix.Length..] : raw;
                        if (pins.IndexOf(tileId) >= 0)
                        {
                            pins.SetPage(page.Id, tileId);
                            SyncSoon();
                            Toast(TileWords.MovedTo(page.Name));
                        }
                    }
                }
                catch (Exception ex) { AppLog.Note("tiles", $"page pill drop failed: {ex.GetType().Name}"); }
                finally { deferral.Complete(); }
            };
            _band.Children.Add(pill);
        }
        var add = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, CornerRadius = new CornerRadius(14), Padding = new Thickness(10, 6, 10, 6) };
        AutomationProperties.SetName(add, TileWords.NewPageTitle);
        AutomationProperties.SetAutomationId(add, "dashboard.page.add");
        add.Click += async (_, _) =>
        {
            if (await AskName(TileWords.NewPageTitle, "", TileWords.Add) is { } name) { pins.AddPage(name); SyncSoon(); }
        };
        _band.Children.Add(add);

        var currentIndex = Math.Max(0, pages.ToList().FindIndex(p => p.Id == pins.CurrentPage));
        var currentPage = pages[currentIndex];
        var more = new Button { Content = new FontIcon { Glyph = "\uE712", FontSize = 12 }, CornerRadius = new CornerRadius(14), Padding = new Thickness(10, 6, 10, 6) };
        AutomationProperties.SetName(more, "Page Options");
        AutomationProperties.SetAutomationId(more, "dashboard.page.menu");
        var moreMenu = PageMenu(pins, currentPage, currentIndex, pages.Count);
        if (!ReadOnlyGateway)
        {
            moreMenu.Items.Add(new MenuFlyoutSeparator());
            Item(moreMenu, TileWords.UpdateAllNow, "\uE72C", () => _ = UpdateAllPageTilesAsync());
            Item(moreMenu, TileWords.PauseAllUpdates, "\uE769", () => _ = SetAllPageTilesPausedAsync(true));
            Item(moreMenu, TileWords.ResumeAllUpdates, "\uE768", () => _ = SetAllPageTilesPausedAsync(false));
        }
        more.Flyout = moreMenu;
        _band.Children.Add(more);
    }

    private MenuFlyout PageMenu(TilePinStore pins, TilePage page, int index, int total)
    {
        var menu = new MenuFlyout();
        var rename = new MenuFlyoutItem { Text = TileWords.Rename, Icon = new FontIcon { Glyph = "" } };
        rename.Click += async (_, _) =>
        {
            if (await AskName(TileWords.RenamePage, page.Name, TileWords.RenameAction) is { } n) { pins.RenamePage(page.Id, n); SyncSoon(); }
        };
        menu.Items.Add(rename);

        var iconMenu = new MenuFlyoutSubItem { Text = TileWords.PageIcon, Icon = new FontIcon { Glyph = "\uE735" } };
        var noneIcon = new RadioMenuFlyoutItem { Text = TileWords.NoIcon, GroupName = "page-icon", IsChecked = string.IsNullOrEmpty(page.Symbol) };
        noneIcon.Click += (_, _) => { pins.SetPageSymbol(page.Id, null); SyncSoon(); };
        iconMenu.Items.Add(noneIcon);
        iconMenu.Items.Add(new MenuFlyoutSeparator());
        foreach (var (sym, label) in TilePage.SymbolChoices)
        {
            var s = sym;
            var item = new RadioMenuFlyoutItem
            {
                Text = label,
                GroupName = "page-icon",
                IsChecked = page.Symbol == s,
                Icon = new FontIcon { Glyph = TileSymbolGlyphs.Glyph(s) },
            };
            item.Click += (_, _) => { pins.SetPageSymbol(page.Id, s); SyncSoon(); };
            iconMenu.Items.Add(item);
        }
        menu.Items.Add(iconMenu);

        if (page.Id != TilePage.MainId)
        {
            if (index > 1)
            {
                var left = new MenuFlyoutItem { Text = "Move Left", Icon = new FontIcon { Glyph = "" } };
                left.Click += (_, _) => { pins.MovePage(page.Id, -1); SyncSoon(); };
                menu.Items.Add(left);
            }
            if (index < total - 1)
            {
                var right = new MenuFlyoutItem { Text = "Move Right", Icon = new FontIcon { Glyph = "" } };
                right.Click += (_, _) => { pins.MovePage(page.Id, 1); SyncSoon(); };
                menu.Items.Add(right);
            }
            menu.Items.Add(new MenuFlyoutSeparator());
            var delete = new MenuFlyoutItem { Text = TileWords.DeletePageAction, Icon = new FontIcon { Glyph = "" } };
            delete.Click += async (_, _) => await ConfirmDeletePage(page);
            menu.Items.Add(delete);
        }
        return menu;
    }

    private async Task ConfirmDeletePage(TilePage page)
    {
        if (_pins == null) return;
        var count = _pins.OnPage(page.Id).Count();
        if (count > 0)
        {
            var main = _pins.Pages.FirstOrDefault()?.Name ?? "Main";
            if (!await Confirm(TileWords.DeletePageTitle(page.Name), TileWords.DeletePageMessage(count, main), TileWords.DeletePageAction)) return;
        }
        _pins.DeletePage(page.Id);
        SyncSoon();
    }

    // ------------------------------------------------------------------ empty state

    private FrameworkElement EmptyState()
    {
        if (_query.Length > 0)
            return Kit.Empty("", TileWords.NoResults, TileWords.NoTileMatches(_query));
        var kept = _pins != null && _hidden != null ? _hidden.Visible(_pins.Pins).ToList() : [];
        var onOtherPages = kept.Any(p => (_scope == "all" || p.Profile == _scope) && _pins!.PageId(p) != _pins.CurrentPage);
        var otherBots = _scope != "all" && kept.Any(p => !ShowsPages || _pins!.PageId(p) == _pins.CurrentPage);
        var title = onOtherPages ? TileWords.ThisPageIsEmpty : otherBots ? TileWords.NoTilesFor(BotName(_scope)) : TileWords.NoTilesYet;

        var open = new Button { Content = TileWords.OpenArtifacts };
        AutomationProperties.SetAutomationId(open, "tile.open-artifacts");
        open.Click += (_, _) => Navigator.Open("artifacts");

        UIElement[] actions;
        if (ReadOnlyGateway)
        {
            actions = [open];
        }
        else
        {
            var newTile = new Button { Content = TileWords.NewTile, Style = Kit.Style("AccentButtonStyle") };
            AutomationProperties.SetAutomationId(newTile, "tile.new");
            newTile.Click += (_, _) => _ = ShowNewTileAsync();
            actions = [newTile, open];
        }

        var state = Kit.Empty("", title, TileWords.HowTo, actions);
        if (state is Grid g && g.Children.Count > 0 && g.Children[0] is StackPanel panel)
        {
            var steps = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center };
            foreach (var (glyph, words) in new[] { ("", TileWords.HowToChat), ("", TileWords.HowToArtifacts) })
                steps.Children.Add(new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 8,
                    Children =
                    {
                        new FontIcon { Glyph = glyph, FontSize = 13, Foreground = Kit.Brush("AccentTextFillColorPrimaryBrush") },
                        Kit.Text(words, 14, secondary: true, wrap: false),
                    },
                });
            panel.Children.Insert(Math.Max(0, panel.Children.Count - 1), steps);
        }
        return state;
    }

    // ------------------------------------------------------------------ New Tile, Change, Duplicate, Keep Updated & Persistence

    private async Task ShowNewTileAsync()
    {
        if (_client == null || _pins == null || XamlRoot == null || ReadOnlyGateway) return;
        var bots = _bots.Count > 0 ? _bots : _client.Bots ?? [];
        var initialBot = _scope != "all" ? _scope : bots.FirstOrDefault()?.Name;
        var req = await NewTileDialog.ShowAsync(XamlRoot, bots, initialBot, _pins.Pages, _pins.CurrentPage, ShowDialog);
        if (req == null) return;
        var prompt = TilePromptBuilder.NewTilePrompt(req.What, req.Size, req.Schedule);
        _ = StartTileMakerAsync(
            req.Bot,
            req.What,
            prompt,
            displayTitle: $"New tile: {req.What}",
            desiredSize: req.Size,
            pageId: req.PageId,
            changingPin: null);
    }

    private async Task ShowChangeTileAsync(TilePin pin, bool duplicate, string initialWhat = "")
    {
        if (_client == null || _pins == null || XamlRoot == null || ReadOnlyGateway || pin.GatewayPath is not { } path) return;
        var bot = _bots.FirstOrDefault(b => b.Name == pin.Profile) ?? _client.Bots?.FirstOrDefault(b => b.Name == pin.Profile);
        if (bot == null) { Toast(TileWords.BotGone); return; }
        string? status = null;
        if (_updates != null)
        {
            var (job, known) = await _updates.LookupAsync(pin);
            if (known && job != null) status = TileJobs.Status(job, DateTimeOffset.Now);
        }
        var tileName = _pins.Name(pin);
        var what = await ChangeTileDialog.ShowAsync(XamlRoot, tileName, bot, duplicate, status, initialWhat, ShowDialog);
        if (what == null) return;
        var prompt = duplicate
            ? TileJobs.DuplicatePrompt(path, tileName, what, pin.TileSize)
            : TilePromptBuilder.ChangePrompt(path, what);
        var display = duplicate ? $"Duplicate {tileName}: {what}" : $"Change tile {tileName}: {what}";
        _ = StartTileMakerAsync(
            bot,
            what,
            prompt,
            displayTitle: display,
            desiredSize: pin.TileSize,
            pageId: _pins.PageId(pin),
            changingPin: duplicate ? null : pin,
            customPath: path);
    }

    private async Task StartKeepUpdatedAsync(TilePin pin, TileJobs.Frequency frequency)
    {
        if (_client == null || _pins == null || ReadOnlyGateway || pin.GatewayPath is not { } path) return;
        var bot = _bots.FirstOrDefault(b => b.Name == pin.Profile) ?? _client.Bots?.FirstOrDefault(b => b.Name == pin.Profile);
        if (bot == null) { Toast(TileWords.BotGone); return; }
        var name = _pins.Name(pin);
        var prompt = TileJobs.SchedulePrompt(path, name, frequency);
        await StartTileMakerAsync(
            bot,
            $"update {frequency.Short}",
            prompt,
            displayTitle: $"Keep {name} updated {frequency.Short}",
            desiredSize: pin.TileSize,
            pageId: _pins.PageId(pin),
            changingPin: pin,
            customPath: path);
    }

    /// Creates a tile chat with `hidden: true` so it never clutters Sessions lists (`TileChats`).
    private async Task<string> CreateHiddenTileChatAsync(Bot bot, CancellationToken ct = default)
    {
        var made = await SessionCreate.CallAsync(
            _client!.Rpc.RequestAsync,
            new JsonObject
            {
                ["profile"] = bot.Name,
                ["follow_profile_config"] = true,
                ["hidden"] = true,
                ["idempotency_key"] = Guid.NewGuid().ToString(),
            },
            bot.Name,
            TimeSpan.FromSeconds(30),
            ct: ct);
        var stored = made.Text("stored_session_id") ?? made.Text("session_id")
            ?? throw new GatewayException("rpc", "Gateway did not return a session id.");
        StartedChats.Note(bot.Name, stored);
        TileChats.RememberChat(_client.AccountId, stored, PendingPrefs);
        return stored;
    }

    private async Task StartTileMakerAsync(
        Bot bot,
        string what,
        string prompt,
        string displayTitle,
        TileSize desiredSize,
        string pageId,
        TilePin? changingPin,
        bool acting = false,
        string? customPath = null,
        Action? onFinished = null)
    {
        if (_client == null || _pins == null) return;
        var accountId = _client.AccountId;
        ChatSession? chat = null;
        ActiveTileMaker? maker = null;
        try
        {
            // [tile-versions] Capture current version before a Change… starts.
            if (changingPin != null && !acting)
                _ = NoteTileVersionAsync(changingPin, TileVersionKind.Outside, null);

            var chatId = acting && changingPin is { SessionId.Length: > 0 }
                ? changingPin.SessionId
                : await CreateHiddenTileChatAsync(bot);

            chat = _client.OpenChat(bot.Name, chatId, displayTitle);
            await chat.OpenAsync();

            var askedAt = DateTimeOffset.UtcNow;
            maker = new ActiveTileMaker
            {
                Id = Guid.NewGuid().ToString("N"),
                AccountId = accountId,
                Bot = bot,
                What = what,
                SessionId = chatId,
                PinId = changingPin?.Id,
                PinName = changingPin != null ? _pins.Name(changingPin) : null,
                Path = customPath ?? changingPin?.GatewayPath ?? "",
                DashboardPage = pageId,
                DesiredSize = desiredSize,
                Acting = acting,
                AskedAt = askedAt,
                Status = "Working…",
            };
            AttachMakerSession(maker, chat, displayTitle, changingPin, onFinished);
            TilePendingStore.Add(maker.ToPending(), PendingPrefs, askedAt);
            ActiveMakers.Add(maker);
            OnUi(Render);
            if (!acting)
                Toast(changingPin != null ? $"{bot.DisplayName} is changing your tile" : $"{bot.DisplayName} is making your tile");

            var outcome = await chat.SendAsync(prompt, display: acting ? null : displayTitle);
            if (outcome == SendOutcome.Refused)
            {
                StopAndRemoveMaker(maker, chat);
                OnUi(() => { Toast(TileWords.CouldntSend); Render(); });
            }
        }
        catch (GatewayException)
        {
            if (maker != null) StopAndRemoveMaker(maker, chat);
            else if (chat != null) await chat.DisposeAsync();
            OnUi(() => { Toast(TileWords.CouldntSend); Render(); });
        }
    }

    /// [tiles-v2] Reattaches to any in-flight tile makers persisted under `hq.tilePendingMakers.<accountId>`.
    private void RestorePendingMakers()
    {
        if (_client == null || _pins == null) return;
        var accountId = _client.AccountId;
        var bots = _bots.Count > 0 ? _bots : _client.Bots ?? [];
        if (bots.Count == 0) return;
        var pending = TilePendingStore.Load(accountId, PendingPrefs);
        if (pending.Count == 0) return;

        foreach (var item in pending)
        {
            if (ActiveMakers.Any(m => m.Id == item.Id || (m.AccountId == accountId && m.SessionId == item.SessionId)))
                continue;
            var bot = bots.FirstOrDefault(b => b.Name == item.BotId);
            if (bot == null)
            {
                TilePendingStore.Remove(item.Id, accountId, PendingPrefs);
                continue;
            }
            var changingPin = item.PinId != null ? _pins.Pins.FirstOrDefault(p => p.Id == item.PinId) : null;
            var displayTitle = item.PinName != null ? $"{item.PinName}: {item.What}" : $"New tile: {item.What}";
            var chat = _client.OpenChat(bot.Name, item.SessionId, displayTitle);
            var maker = new ActiveTileMaker
            {
                Id = item.Id,
                AccountId = accountId,
                Bot = bot,
                What = item.What,
                SessionId = item.SessionId,
                PinId = item.PinId,
                PinName = item.PinName,
                Path = item.Path,
                DashboardPage = item.DashboardPage,
                DesiredSize = item.DesiredSize,
                Acting = item.Acting,
                AskedAt = DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(item.AskedAt * 1000)),
                Status = "Working…",
            };
            AttachMakerSession(maker, chat, displayTitle, changingPin, onFinished: null);
            ActiveMakers.Add(maker);
            _ = OpenRestoredMakerAsync(maker, chat, displayTitle, changingPin);
        }
    }

    private async Task OpenRestoredMakerAsync(ActiveTileMaker maker, ChatSession chat, string displayTitle, TilePin? changingPin)
    {
        try
        {
            await chat.OpenAsync();
            if (!maker.Watching) return;
            UpdateMakerStepWords(maker, chat);
            if (!chat.Busy)
                await CompleteMakerAsync(maker, chat, displayTitle, changingPin, onFinished: null);
        }
        catch (Exception)
        {
            if (maker.Watching) StopAndRemoveMaker(maker, chat);
        }
    }

    private void AttachMakerSession(ActiveTileMaker maker, ChatSession chat, string displayTitle, TilePin? changingPin, Action? onFinished)
    {
        var completing = 0;
        void OnChanged()
        {
            if (!maker.Watching) return;
            UpdateMakerStepWords(maker, chat);
        }
        void OnTurnEnded(bool ended)
        {
            if (!maker.Watching || Interlocked.Exchange(ref completing, 1) != 0) return;
            chat.Changed -= OnChanged;
            chat.TurnEnded -= OnTurnEnded;
            _ = CompleteMakerAsync(maker, chat, displayTitle, changingPin, onFinished);
        }
        maker.CancelAction = () =>
        {
            chat.Changed -= OnChanged;
            chat.TurnEnded -= OnTurnEnded;
            StopAndRemoveMaker(maker, chat, stopTurn: true);
            OnUi(Render);
        };
        chat.Changed += OnChanged;
        chat.TurnEnded += OnTurnEnded;
    }

    private void StopAndRemoveMaker(ActiveTileMaker maker, ChatSession? chat, bool stopTurn = false)
    {
        maker.Watching = false;
        ActiveMakers.Remove(maker);
        TilePendingStore.Remove(maker.Id, maker.AccountId, PendingPrefs);
        if (chat != null)
        {
            if (stopTurn) _ = chat.StopAsync();
            _ = chat.DisposeAsync().AsTask();
        }
    }

    private void UpdateMakerStepWords(ActiveTileMaker maker, ChatSession chat)
    {
        var runningTool = chat.Messages
            .LastOrDefault(m => m.Role == Role.Assistant)?
            .Tools.LastOrDefault(t => t.State == ToolState.Running)?.Title;
        var next = !string.IsNullOrWhiteSpace(runningTool)
            ? runningTool!
            : !string.IsNullOrWhiteSpace(chat.Status)
                ? chat.Status!
                : chat.Busy ? "Working…" : "Finishing…";
        if (maker.Status == next) return;
        maker.Status = next;
        OnUi(() =>
        {
            RenderMakingBar(AccountMakers());
            if (maker.PinId != null && _cells.TryGetValue(maker.PinId, out var cell))
                cell.SetWorking(maker.TileWords);
        });
    }

    private static string? ExtractHandedOverPath(ChatSession chat, DateTimeOffset askedAt)
    {
        var cutoff = askedAt.AddSeconds(-5);
        var text = string.Join("\n", chat.Messages
            .Where(m => m.Role == Role.Assistant && (m.Timestamp ?? DateTimeOffset.MaxValue) >= cutoff)
            .Select(m => m.Text));
        return TileWebTheme.ExtractPagePath(text);
    }

    private static string? FindTurnError(ChatSession chat, DateTimeOffset askedAt)
    {
        var cutoff = askedAt.AddSeconds(-5);
        return chat.Messages
            .LastOrDefault(m => !string.IsNullOrWhiteSpace(m.Error) && (m.Timestamp ?? DateTimeOffset.MaxValue) >= cutoff)?
            .Error;
    }

    private async Task CompleteMakerAsync(ActiveTileMaker maker, ChatSession chat, string displayTitle, TilePin? changingPin, Action? onFinished)
    {
        // [tiles-v2] 12 s replyGrace retries ([1, 3, 6, 12] s) when turn ends without a page path and without an error.
        string? handedPath = ExtractHandedOverPath(chat, maker.AskedAt);
        string? problem = FindTurnError(chat, maker.AskedAt);
        if (!maker.Acting && handedPath == null && problem == null)
        {
            var prev = 0;
            foreach (var sec in TileWebTheme.ReplyGraceDelaysSeconds)
            {
                if (!maker.Watching) break;
                try { await Task.Delay(TimeSpan.FromSeconds(sec - prev)); } catch (OperationCanceledException) { break; }
                prev = sec;
                if (!maker.Watching) break;
                try { await chat.RefreshAsync(); } catch (Exception) { }
                handedPath = ExtractHandedOverPath(chat, maker.AskedAt);
                problem = FindTurnError(chat, maker.AskedAt);
                if (handedPath != null || problem != null) break;
            }
        }

        maker.Watching = false;
        ActiveMakers.Remove(maker);
        TilePendingStore.Remove(maker.Id, maker.AccountId, PendingPrefs);
        TileChats.RememberChat(maker.AccountId, maker.SessionId, PendingPrefs);

        var sessionId = maker.SessionId;
        var bot = maker.Bot;
        var what = maker.What;
        var desiredSize = maker.DesiredSize ?? TileSize.Small;
        var pageId = maker.DashboardPage;
        var activeChangingPin = changingPin ?? (maker.PinId != null ? _pins?.Pins.FirstOrDefault(p => p.Id == maker.PinId) : null);

        OnUi(() =>
        {
            if (_pins != null && activeChangingPin != null)
            {
                _pins.NoteChat(activeChangingPin.Id, sessionId, displayTitle);
                SyncSoon();
            }

            if (activeChangingPin != null)
            {
                var pinName = _pins?.Name(activeChangingPin) ?? activeChangingPin.Name;
                if (maker.Acting)
                {
                    Reread(activeChangingPin.Id);
                    onFinished?.Invoke();
                    if (problem != null) Toast($"Couldn’t Update {pinName}");
                    Render();
                    return;
                }

                Reread(activeChangingPin.Id);
                _ = NoteTileVersionAsync(activeChangingPin, TileVersionKind.Changed, what);
                var done = problem == null && handedPath != null;
                if (problem != null)
                {
                    var retryPin = activeChangingPin;
                    _ = TileMakerFailureDialog.ShowAsync(
                        XamlRoot,
                        $"Couldn’t Change {pinName}",
                        $"{bot.DisplayName} stopped with a problem: {TileWebTheme.FirstLine(problem)} Open the chat to see what happened, or ask again.",
                        openChat: () => Navigator.Go(new ChatDestination(bot.Name, sessionId, displayTitle)),
                        retry: () =>
                        {
                            if (retryPin.GatewayPath is { } p)
                                _ = StartTileMakerAsync(bot, what, TilePromptBuilder.ChangePrompt(p, what), displayTitle, retryPin.TileSize, _pins?.PageId(retryPin) ?? TilePage.MainId, retryPin, customPath: p);
                        },
                        ShowDialog);
                }
                else if (!done)
                {
                    _ = TileMakerFailureDialog.ShowAsync(
                        XamlRoot,
                        $"{bot.DisplayName} Needs You",
                        $"{bot.DisplayName} didn’t say the change is done. It may have a question for you. Open the chat to see what it said.",
                        openChat: () => Navigator.Go(new ChatDestination(bot.Name, sessionId, displayTitle)),
                        retry: null,
                        ShowDialog);
                }
                else
                {
                    FlashChangedRing(activeChangingPin.Id);
                    Toast($"{pinName} Changed");
                }
                Render();
                return;
            }

            if (handedPath != null && _pins != null)
            {
                var pin = TilePin.Make(TileKind.File, handedPath, "", bot.Name, sessionId, displayTitle) with
                {
                    Size = desiredSize,
                    Page = pageId == TilePage.MainId ? null : pageId,
                    ChatAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
                };
                if (!_pins.Pin(pin))
                {
                    _ = TileMakerFailureDialog.ShowAsync(
                        XamlRoot,
                        $"{bot.DisplayName} Needs You",
                        $"You already have {TilePinStore.Limit} tiles pinned. Unpin one to add another. Your new page is in the chat.",
                        openChat: () => Navigator.Go(new ChatDestination(bot.Name, sessionId, displayTitle)),
                        retry: null,
                        ShowDialog);
                }
                else
                {
                    SyncSoon();
                    _ = NoteTileVersionAsync(pin, TileVersionKind.Made, what);
                    Toast("Your New Tile Is Pinned");
                }
            }
            else if (problem != null)
            {
                _ = TileMakerFailureDialog.ShowAsync(
                    XamlRoot,
                    "Couldn’t Make the Tile",
                    $"{bot.DisplayName} stopped with a problem: {TileWebTheme.FirstLine(problem)} Open the chat to see what happened.",
                    openChat: () => Navigator.Go(new ChatDestination(bot.Name, sessionId, displayTitle)),
                    retry: null,
                    ShowDialog);
            }
            else
            {
                _ = TileMakerFailureDialog.ShowAsync(
                    XamlRoot,
                    $"{bot.DisplayName} Needs You",
                    $"{bot.DisplayName} didn’t hand over a tile yet. Open the chat to see what it said.",
                    openChat: () => Navigator.Go(new ChatDestination(bot.Name, sessionId, displayTitle)),
                    retry: null,
                    ShowDialog);
            }
            Render();
        });
        _ = chat.DisposeAsync().AsTask();
    }

    private void FlashChangedRing(string pinId)
    {
        _ringedPins.Add(pinId);
        if (_cells.TryGetValue(pinId, out var cell)) cell.SetRinged(true);
        _ = Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(4));
            OnUi(() =>
            {
                _ringedPins.Remove(pinId);
                if (_cells.TryGetValue(pinId, out var c)) c.SetRinged(false);
            });
        });
    }

    private async Task NoteTileVersionAsync(TilePin pin, TileVersionKind kind, string? what)
    {
        if (_client == null || _pins == null || ReadOnlyGateway || !pin.IsPage || pin.GatewayPath is not { } path) return;
        try
        {
            var store = new TileVersionStore(_client.Session, pin.Profile, path);
            var list = await store.NoteAsync(kind, what);
            if (list.Current > 0)
            {
                OnUi(() =>
                {
                    _pins?.NoteVersion(pin.Id, list.Current);
                    SyncSoon();
                });
            }
        }
        catch (Exception) { }
    }

    private async Task ShowActivityAsync()
    {
        if (_client == null || _pins == null || _updates == null || XamlRoot == null) return;
        var pages = (_hidden != null ? _hidden.Visible(_pins.Pins) : _pins.Pins).Where(p => p.IsPage).ToList();
        await _updates.PrefetchAsync(pages.Select(p => p.Profile));
        var scheduled = new List<TileActivityRow>();
        foreach (var pin in pages)
        {
            var (job, known) = await _updates.LookupAsync(pin);
            if (!known || job == null) continue;
            var bot = _bots.FirstOrDefault(b => b.Name == pin.Profile);
            var botModel = bot?.Model is { Length: > 0 } m ? ModelNames.DisplayModelName(m) : null;
            scheduled.Add(new TileActivityRow(pin, _pins.Name(pin), BotName(pin.Profile), botModel, job));
        }
        await TileActivityDialog.ShowAsync(
            XamlRoot,
            AccountMakers(),
            scheduled,
            openMakerChat: m => Navigator.Go(new ChatDestination(m.Bot.Name, m.SessionId, m.DisplayTitle)),
            cancelMaker: m => m.CancelAction?.Invoke(),
            runJob: async job => await Write(() => _updates.RunNowAsync(job), TileWords.Updating, TileWords.CouldntUpdate),
            setJobPaused: async (job, pause) => await Write(() => _updates.SetPausedAsync(job, pause),
                pause ? TileWords.UpdatesPaused : TileWords.UpdatesResumed, TileWords.CouldntChangeUpdates),
            updateAll: UpdateAllPageTilesAsync,
            setAllPaused: SetAllPageTilesPausedAsync,
            show: ShowDialog);
    }

    private async Task UpdateAllPageTilesAsync()
    {
        if (_updates == null || ReadOnlyGateway) return;
        var pages = Visible().Where(p => p.IsPage).ToList();
        await _updates.PrefetchAsync(pages.Select(p => p.Profile));
        var triggered = 0;
        foreach (var pin in pages)
        {
            var (job, known) = await _updates.LookupAsync(pin);
            if (!known || job == null || TileJobs.IsPaused(job)) continue;
            if (await Write(() => _updates.RunNowAsync(job), null, TileWords.CouldntUpdate))
            {
                triggered++;
                Reread(pin.Id);
            }
        }
        Toast(triggered == 0 ? "No active tile jobs on this page" : $"Updating {triggered} {(triggered == 1 ? "tile" : "tiles")}…");
    }

    private async Task SetAllPageTilesPausedAsync(bool pause)
    {
        if (_updates == null || ReadOnlyGateway) return;
        var pages = Visible().Where(p => p.IsPage).ToList();
        await _updates.PrefetchAsync(pages.Select(p => p.Profile));
        var changed = 0;
        foreach (var pin in pages)
        {
            var (job, known) = await _updates.LookupAsync(pin);
            if (!known || job == null || TileJobs.IsPaused(job) == pause) continue;
            if (await Write(() => _updates.SetPausedAsync(job, pause), null, TileWords.CouldntChangeUpdates)) changed++;
        }
        Toast(changed == 0
            ? (pause ? "All tile updates already paused" : "No paused tile updates on this page")
            : (pause ? TileWords.UpdatesPaused : TileWords.UpdatesResumed));
    }

    // ------------------------------------------------------------------ a tile's menu

    private void FillMenu(MenuFlyout menu, TilePin pin)
    {
        menu.Items.Clear();
        if (_pins == null) return;
        var pins = _pins;
        var name = pins.Name(pin);
        menu.Items.Add(new MenuFlyoutItem { Text = name, IsEnabled = false });
        if (View == TilesView.Grid)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(new MenuFlyoutItem { Text = TileWords.Size, IsEnabled = false });
            foreach (var size in TileSizes.All)
            {
                var item = new RadioMenuFlyoutItem { Text = size.Title(), GroupName = "size", IsChecked = pin.TileSize == size };
                AutomationProperties.SetAutomationId(item, "pin.size." + size.Raw());
                item.Click += (_, _) => { pins.SetSize(size, pin.Id); SyncSoon(); };
                menu.Items.Add(item);
            }
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        Item(menu, TileWords.Open, pin.IsPage ? "" : "", () => Open(pin));
        if (pin.SessionId.Length > 0) Item(menu, TileWords.ShowInChat, "", () => ShowInChat(pin));
        if (pin.IsPage)
        {
            var shareImg = new MenuFlyoutItem { Text = "Share as Image…", Icon = new FontIcon { Glyph = "\uEB9F" } };
            AutomationProperties.SetAutomationId(shareImg, "tile.share-image");
            shareImg.Click += (_, _) => _ = ShareAsImageAsync(pin);
            menu.Items.Add(shareImg);
        }
        if (pin.Kind != TileKind.Link) Item(menu, TileWords.Share, "", () => _ = Share(pin));
        if (pin.Kind != TileKind.Link && TileFiles.IsGatewayFile(pin)) Item(menu, TileWords.SaveAs, "", () => _ = SaveAs(pin));
        Item(menu, pin.Kind == TileKind.Link ? TileWords.CopyLink : TileWords.CopyPath, "", () =>
        {
            MediaActions.CopyText(pin.Value);
            Toast(TileWords.Copied);
        });
        menu.Items.Add(new MenuFlyoutSeparator());
        if (pin.IsPage)
        {
            if (!ReadOnlyGateway && pin.GatewayPath != null)
            {
                Item(menu, TileWords.Change, "\uE70F", () => _ = ShowChangeTileAsync(pin, duplicate: false));
                Item(menu, TileWords.Duplicate, "\uE8C8", () => _ = ShowChangeTileAsync(pin, duplicate: true));
            }
            menu.Items.Add(UpdatesMenu(pin));
        }
        if (VersionsItem(pin) is { } versions) menu.Items.Add(versions);
        Item(menu, TileWords.Rename, "", () => _ = RenameTile(pin));
        if (ShowsPages)
        {
            var move = new MenuFlyoutSubItem { Text = TileWords.MoveToPage, Icon = new FontIcon { Glyph = "" } };
            var here = pins.PageId(pin);
            foreach (var page in pins.Pages.Where(p => p.Id != here))
            {
                var p = page;
                var item = new MenuFlyoutItem { Text = p.Name };
                item.Click += (_, _) => { pins.SetPage(p.Id, pin.Id); SyncSoon(); Toast(TileWords.MovedTo(p.Name)); };
                move.Items.Add(item);
            }
            if (move.Items.Count > 0) move.Items.Add(new MenuFlyoutSeparator());
            var newPage = new MenuFlyoutItem { Text = TileWords.NewPage, Icon = new FontIcon { Glyph = "" } };
            newPage.Click += async (_, _) =>
            {
                if (await AskName(TileWords.NewPageTitle, "", TileWords.Add) is not { } n) return;
                var page = pins.AddPage(n);
                pins.SetPage(page.Id, pin.Id);
                SyncSoon();
            };
            move.Items.Add(newPage);
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(move);
        }
        if (View == TilesView.Grid)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            Item(menu, TileWords.EditTiles, "", () => SetEditing(true));
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Features.QuickActions.FavoritesPinAction.ForDashboardTile(pin.Id, name, null, added => Toast(added ? "Added to Favorites" : "Removed from Favorites")));
        Item(menu, TileWords.Unpin, "", () => Unpin(pin));
        menu.Items.Add(new MenuFlyoutSeparator());
        Item(menu, TileWords.Remove, "", () => _ = ConfirmRemove(pin, name));
    }

    private static void Item(MenuFlyout menu, string text, string glyph, Action run)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
        item.Click += (_, _) => run();
        menu.Items.Add(item);
    }

    private bool ReadOnlyGateway => CommandCenterModel.IsReadOnlyGateway(_client);

    /// [tile-versions] Offered on both writable and read-only gateways for HTML page tiles.
    private MenuFlyoutItem? VersionsItem(TilePin pin)
    {
        var offer = TileVersionsModel.Offer(pin, ReadOnlyGateway, supportsWritable: true);
        if (offer == TileVersionsOffer.Hidden) return null;
        var item = new MenuFlyoutItem { Text = TileVersionsModel.Title, Icon = new FontIcon { Glyph = "\uE81C" }, IsEnabled = offer == TileVersionsOffer.Enabled };
        AutomationProperties.SetAutomationId(item, "tile.versions");
        if (TileVersionsModel.MenuSubtitle(pin) is { } shown) ToolTipService.SetToolTip(item, shown);
        item.Click += (_, _) => _ = ShowVersions(pin);
        return item;
    }

    private async Task ShowVersions(TilePin kept)
    {
        if (_client == null || _pins == null || XamlRoot == null) return;
        var session = _client.Session;
        var pin = _pins.Pins.FirstOrDefault(p => p.Id == kept.Id) ?? kept;
        var name = _pins.Name(pin);
        var hasJob = false;
        if (_updates != null)
        {
            var (job, known) = await _updates.LookupAsync(pin);
            hasJob = known && job != null;
        }
        var model = ReadOnlyGateway
            ? new TileVersionsModel(pin, name, path => new TileVersionReader(session, pin.Profile, path))
            : TileVersionsModel.WritableFor(pin, name, path => new TileVersionStore(session, pin.Profile, path));
        await TileVersionsSheet.ShowAsync(
            XamlRoot,
            model,
            OpenVersion,
            ShowDialog,
            onRolledBack: number =>
            {
                _pins.NoteVersion(pin.Id, number);
                SyncSoon();
                Reread(pin.Id);
                Toast(TileWords.VersionShownToast(name, number));
                if (hasJob && pin.GatewayPath is { } path && _bots.FirstOrDefault(b => b.Name == pin.Profile) is { } bot)
                    _ = NotifyRolledBackAsync(pin, path, bot, name, number);
            },
            botName: BotName(pin.Profile),
            hasJob: hasJob);
    }

    private async Task NotifyRolledBackAsync(TilePin pin, string path, Bot bot, string name, int version)
    {
        if (_client == null) return;
        await StartTileMakerAsync(
            bot,
            $"its updates follow Version {version}",
            TilePromptBuilder.RolledBackPrompt(path, name, version),
            displayTitle: $"Rolled back {name} to Version {version}",
            desiredSize: pin.TileSize,
            pageId: _pins?.PageId(pin) ?? TilePage.MainId,
            changingPin: pin,
            acting: true,
            customPath: path);
    }

    /// A version full size, as the tile opens (its page's buttons go nowhere: a version isn't the tile).
    private void OpenVersion(TilePin version, string title)
    {
        if (_client == null) return;
        _viewer?.Close();
        var viewer = new TileViewer(_client.Session, version, title, null);
        viewer.Closed += () => { _overlay.Children.Remove(viewer); if (_viewer == viewer) _viewer = null; };
        viewer.ShareRequested += p => _ = Share(p);
        _viewer = viewer;
        _overlay.Children.Add(viewer);
    }

    /// Updates (TileUpdates.menu): Keep Updated… schedule submenu when static; else Model override submenu,
    /// Last Update Failed + Fix with Bot + View Last Run / View Job, How Often, Update/Retry Now (4s active polling), Pause/Resume.
    private MenuFlyoutSubItem UpdatesMenu(TilePin pin)
    {
        var sub = new MenuFlyoutSubItem { Text = TileWords.Updates, Icon = new FontIcon { Glyph = "" } };
        AutomationProperties.SetAutomationId(sub, "tile.updates");
        sub.Items.Add(new MenuFlyoutItem { Text = TileWords.Updating, IsEnabled = false });
        _ = FillUpdates(sub, pin);
        return sub;
    }

    private async Task FillUpdates(MenuFlyoutSubItem sub, TilePin pin)
    {
        if (_updates == null || _client == null || AppShutdown.Stopping) return;
        var updates = _updates;
        var client = _client;
        var accountId = client.AccountId;
        var writable = !ReadOnlyGateway;
        (TileCronJob? job, bool known) result;
        try { result = await updates.LookupAsync(pin); }
        catch (Exception) { return; }
        if (AppShutdown.Stopping || _life == null) return;
        var (job, known) = result;

        var bot = _bots.FirstOrDefault(b => b.Name == pin.Profile);
        var botName = BotName(pin.Profile);
        var rosterModel = bot?.Model is { Length: > 0 } m ? ModelNames.DisplayModelName(m) : null;
        string? botModel = rosterModel;
        TileModelPick? modelOverride = null;
        TileModelPick? defaultModel = null;
        List<TileModelPick> shortList = [];

        if (known && job != null && !TileModels.IsScriptOnly(job))
        {
            var settings = new TileModelSettings(accountId, TileModelPrefs);
            modelOverride = settings.Override(job.Key);
            defaultModel = settings.DefaultModel;
            if (writable)
                _ = TileModelSync.Shared.ReconcileAsync(job, accountId, TileModelPrefs, updates, readOnlyGateway: false, force: false);
            botModel = await TileModelSync.Shared.BotModelAsync(pin.Profile, rosterModel, accountId, client.Session);
            shortList = await TileModelSync.Shared.ShortListAsync(accountId, pin.Profile, ComposerServices.Store, client.Session, modelOverride);
            if (AppShutdown.Stopping || _life == null) return;
        }

        try
        {
            sub.Items.Clear();
            if (!known)
            {
                sub.Text = TileWords.CouldntReadUpdates;
                sub.Items.Add(new MenuFlyoutItem { Text = TileWords.CantReachGateway, IsEnabled = false });
                return;
            }
            if (job == null)
            {
                if (writable && pin.GatewayPath != null)
                {
                    sub.Text = "Keep Updated…";
                    AutomationProperties.SetAutomationId(sub, "tile.updates.attach");
                    ToolTipService.SetToolTip(sub, $"Ask {botName} to schedule refreshes");
                    foreach (var f in TileJobs.Frequencies)
                    {
                        var freq = f;
                        var attach = new MenuFlyoutItem { Text = freq.Title };
                        AutomationProperties.SetAutomationId(attach, $"tile.updates.attach-{freq.Minutes}");
                        attach.Click += (_, _) => _ = StartKeepUpdatedAsync(pin, freq);
                        sub.Items.Add(attach);
                    }
                    return;
                }
                sub.Text = TileWords.NotKeptUpdated;
                AutomationProperties.SetAutomationId(sub, "tile.updates.none");
                sub.Items.Add(new MenuFlyoutItem { Text = TileWords.NoJobRewrites, IsEnabled = false });
                return;
            }

            ToolTipService.SetToolTip(sub, TileModels.UpdatesSubtitle(job, botModel, DateTimeOffset.Now));

            // Model row / Model override submenu
            if (TileModels.IsScriptOnly(job))
            {
                var scriptItem = new MenuFlyoutItem
                {
                    Text = TileJobs.ModelWords(job, botName, botModel),
                    IsEnabled = false,
                    Icon = new FontIcon { Glyph = "" },
                };
                AutomationProperties.SetAutomationId(scriptItem, "tile.updates.model");
                sub.Items.Add(scriptItem);
            }
            else
            {
                var modelSub = new MenuFlyoutSubItem
                {
                    Text = "Model",
                    Icon = new FontIcon { Glyph = "" },
                };
                AutomationProperties.SetAutomationId(modelSub, "tile.updates.model");
                ToolTipService.SetToolTip(modelSub, TileModels.ModelSubtitle(job, botName, botModel));

                var useDefault = new RadioMenuFlyoutItem
                {
                    Text = TileModels.UseDefaultTitle(defaultModel, botName, botModel),
                    GroupName = "tile-model",
                    IsChecked = modelOverride == null,
                    IsEnabled = writable,
                };
                AutomationProperties.SetAutomationId(useDefault, "tile.model.default");
                useDefault.Click += (_, _) => _ = ApplyTileModelAsync(pin, job, null);
                modelSub.Items.Add(useDefault);

                if (shortList.Count > 0)
                {
                    modelSub.Items.Add(new MenuFlyoutSeparator());
                    foreach (var pick in shortList)
                    {
                        var p = pick;
                        var chosen = modelOverride != null && modelOverride.Same(p);
                        var opt = new RadioMenuFlyoutItem
                        {
                            Text = TileModels.Name(p),
                            GroupName = "tile-model",
                            IsChecked = chosen,
                            IsEnabled = writable,
                        };
                        if (p.Provider.Length > 0) ToolTipService.SetToolTip(opt, ModelNames.PlainProviderName(p.Provider));
                        AutomationProperties.SetAutomationId(opt, $"tile.model.option.{p.Model}");
                        opt.Click += (_, _) => _ = ApplyTileModelAsync(pin, job, p);
                        modelSub.Items.Add(opt);
                    }
                }
                modelSub.Items.Add(new MenuFlyoutSeparator());
                var other = new MenuFlyoutItem
                {
                    Text = "Other Model…",
                    Icon = new FontIcon { Glyph = "\uE712" },
                    IsEnabled = writable,
                };
                AutomationProperties.SetAutomationId(other, "tile.model.other");
                other.Click += async (_, _) =>
                {
                    var chosen = await TileModelChooserDialog.ShowAsync(XamlRoot, client.Session, pin.Profile, botName, modelOverride, ShowDialog);
                    if (chosen != null) await ApplyTileModelAsync(pin, job, chosen);
                };
                modelSub.Items.Add(other);
                sub.Items.Add(modelSub);
            }

            var health = TileJobs.HealthOf(job, DateTimeOffset.Now);
            var isFailed = health.Kind == TileJobs.HealthKind.Failed;
            if (isFailed)
            {
                var failedItem = new MenuFlyoutItem
                {
                    Text = TileWords.LastUpdateFailed + (health.Why is { } why ? " — " + (why.Length > 120 ? why[..120] : why) : ""),
                    IsEnabled = false,
                };
                AutomationProperties.SetAutomationId(failedItem, "tile.updates.failed");
                sub.Items.Add(failedItem);
                if (writable && pin.GatewayPath != null)
                {
                    var fix = new MenuFlyoutItem
                    {
                        Text = $"Fix with {botName}…",
                        Icon = new FontIcon { Glyph = "\uE90F" },
                    };
                    AutomationProperties.SetAutomationId(fix, "tile.updates.fix");
                    fix.Click += (_, _) => _ = ShowChangeTileAsync(pin, duplicate: false, initialWhat: TileJobs.FixPrefill(health.Why));
                    sub.Items.Add(fix);
                }
                var viewRun = new MenuFlyoutItem
                {
                    Text = "View Last Run",
                    Icon = new FontIcon { Glyph = "\uE8A5" },
                };
                AutomationProperties.SetAutomationId(viewRun, "tile.updates.view-run");
                viewRun.Click += (_, _) => Navigator.Open("jobs", job.Key);
                sub.Items.Add(viewRun);
            }
            else
            {
                var viewJob = new MenuFlyoutItem
                {
                    Text = "View Job",
                    Icon = new FontIcon { Glyph = "\uE823" },
                };
                AutomationProperties.SetAutomationId(viewJob, "tile.updates.view-job");
                viewJob.Click += (_, _) => Navigator.Open("jobs", job.Key);
                sub.Items.Add(viewJob);
            }

            sub.Items.Add(new MenuFlyoutSeparator());
            sub.Items.Add(new MenuFlyoutItem { Text = TileWords.HowOften, IsEnabled = false });
            var current = TileJobs.FrequencyOf(job);
            if (current == null)
            {
                var often = TileJobs.HowOften(job);
                sub.Items.Add(new RadioMenuFlyoutItem { Text = char.ToUpperInvariant(often[0]) + often[1..], IsChecked = true, GroupName = "often", IsEnabled = writable });
            }
            foreach (var f in TileJobs.Frequencies)
            {
                var freq = f;
                var item = new RadioMenuFlyoutItem { Text = freq.Title, GroupName = "often", IsChecked = current == freq, IsEnabled = writable };
                AutomationProperties.SetAutomationId(item, $"tile.updates.every-{freq.Minutes}");
                item.Click += async (_, _) => await Write(() => updates.SetFrequencyAsync(job, freq), TileWords.UpdatesEvery(freq.Title), TileWords.CouldntChangeUpdates);
                sub.Items.Add(item);
            }
            sub.Items.Add(new MenuFlyoutSeparator());
            var now = new MenuFlyoutItem
            {
                Text = isFailed ? "Retry Now" : TileWords.UpdateNow,
                Icon = new FontIcon { Glyph = "" },
                IsEnabled = writable,
            };
            AutomationProperties.SetAutomationId(now, "tile.updates.now");
            now.Click += async (_, _) =>
            {
                Toast(TileWords.Updating);
                var ct = _life?.Token ?? CancellationToken.None;
                try
                {
                    await updates.UpdateNowAndPollAsync(
                        job,
                        pin,
                        onFinished: _ => OnUi(() =>
                        {
                            if (AppShutdown.Stopping || _life == null) return;
                            Reread(pin.Id);
                        }),
                        ct: ct);
                }
                catch (GatewayException)
                {
                    Toast(TileWords.CouldntUpdate);
                }
            };
            sub.Items.Add(now);
            var paused = TileJobs.IsPaused(job);
            var pause = new MenuFlyoutItem
            {
                Text = paused ? TileWords.ResumeUpdates : TileWords.PauseUpdates,
                Icon = new FontIcon { Glyph = paused ? "" : "" },
                IsEnabled = writable,
            };
            AutomationProperties.SetAutomationId(pause, "tile.updates.pause");
            pause.Click += async (_, _) => await Write(() => updates.SetPausedAsync(job, !paused),
                paused ? TileWords.UpdatesResumed : TileWords.UpdatesPaused, TileWords.CouldntChangeUpdates);
            sub.Items.Add(pause);
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or InvalidOperationException) { }
    }

    private async Task ApplyTileModelAsync(TilePin pin, TileCronJob job, TileModelPick? pick)
    {
        if (_client == null || _updates == null || _pins == null || ReadOnlyGateway) return;
        var accountId = _client.AccountId;
        var settings = new TileModelSettings(accountId, TileModelPrefs);
        settings.SetOverride(pick, job.Key);
        _pins.SetModelOverride(pin.Id, pick?.Provider, pick?.Model);
        SyncSoon();
        var outcome = await TileModelSync.Shared.ReconcileAsync(job, accountId, TileModelPrefs, _updates, ReadOnlyGateway, force: true);
        _updates.Forget(pin.Profile);
        if (outcome.Kind == TileModelSync.OutcomeKind.Failed)
            Toast("Couldn’t Change the Model");
        else
            Toast(pick != null ? TileModels.Name(pick) : "Tile Default");
    }

    private async Task<bool> Write(Func<Task> write, string? done, string failed)
    {
        try
        {
            await write();
            if (done != null) Toast(done);
            return true;
        }
        catch (GatewayException)
        {
            Toast(failed);
            return false;
        }
    }

    // ------------------------------------------------------------------ actions

    private void Open(TilePin pin)
    {
        if (_client == null || _editing) return;
        switch (TileFiles.OpeningOf(pin))
        {
            case TileFiles.Opening.Link:
                if (Uri.TryCreate(pin.Value, UriKind.Absolute, out var u) && u.Scheme is "http" or "https") _ = Windows.System.Launcher.LaunchUriAsync(u);
                return;
            case TileFiles.Opening.Other:
                _ = OpenOutside(pin);
                return;
        }
        _viewer?.Close();
        var viewer = new TileViewer(_client.Session, pin, _pins?.Name(pin) ?? pin.Name, null);
        viewer.Closed += () => { _overlay.Children.Remove(viewer); if (_viewer == viewer) _viewer = null; };
        viewer.ShareRequested += p => _ = Share(p);
        viewer.WebMessage += (p, m, web) => OnWebMessage(p, m, web);
        _viewer = viewer;
        _overlay.Children.Add(viewer);
        var updates = _updates;
        if (pin.IsPage && updates != null)
            _ = Task.Run(async () =>
            {
                var (job, _) = await updates.LookupAsync(pin);
                if (job != null) OnUi(() => viewer.SetStatus(TileJobs.ShortStatus(job, DateTimeOffset.Now)));
            });
    }

    /// [tiles-v2] Captures a rendered PNG snapshot of a page tile and opens the Windows share sheet (`Share as Image…`).
    private async Task ShareAsImageAsync(TilePin pin)
    {
        byte[]? png = null;
        if (_cells.TryGetValue(pin.Id, out var cell))
            png = await cell.CapturePngAsync();
        if (png == null && _viewer?.Pin.Id == pin.Id && _viewer.WebView is { } viewerWeb)
            png = await TileWeb.CapturePngAsync(viewerWeb);
        if (png == null || png.Length == 0)
        {
            Toast("Open the tile first to render its image");
            return;
        }
        try
        {
            var title = _pins?.Name(pin) ?? pin.Name;
            var safe = Hermes.Core.Attachments.AttachmentCenter.SafeName(string.IsNullOrWhiteSpace(title) ? "Tile" : title);
            if (!safe.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) safe += ".png";
            var folder = Path.Combine(Path.GetTempPath(), "HQNTileImage-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            var file = Path.Combine(folder, safe);
            await File.WriteAllBytesAsync(file, png);
            await MediaActions.ShareAsync(file, safe);
        }
        catch (Exception e) when (e is IOException or System.Runtime.InteropServices.COMException)
        {
            Toast("Couldn’t Render Tile Image");
        }
    }

    /// A file the app has no viewer for (a PDF, a spreadsheet): read, then opened in its own app.
    private async Task OpenOutside(TilePin pin)
    {
        if (await LocalCopy(pin) is { } path) await MediaActions.OpenAsync(path, pin.Label);
    }

    private async Task<string?> LocalCopy(TilePin pin)
    {
        if (_client == null) return null;
        try
        {
            var bytes = await TileFiles.BytesAsync(_client.Session, pin);
            var folder = Path.Combine(Path.GetTempPath(), "HQNTiles-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            var path = Path.Combine(folder, Hermes.Core.Attachments.AttachmentCenter.SafeName(pin.Label.Length > 0 ? pin.Label : "file"));
            await File.WriteAllBytesAsync(path, bytes);
            return path;
        }
        catch (Exception e) when (e is GatewayException or PagesMessageException or IOException)
        {
            await MediaActions.AlertAsync(XamlRoot, "Couldn’t Open File", TileFiles.FailureText(e, pin.Kind == TileKind.Image));
            return null;
        }
    }

    private async Task Share(TilePin pin)
    {
        if (await LocalCopy(pin) is { } path) await MediaActions.ShareAsync(path, pin.Label);
    }

    private async Task SaveAs(TilePin pin)
    {
        if (await LocalCopy(pin) is { } path) await MediaActions.SaveAsAsync(path, pin.Label);
    }

    private static void ShowInChat(TilePin pin) =>
        Navigator.Go(new ChatDestination(pin.Profile, pin.SessionId, pin.SessionTitle.Length > 0 ? pin.SessionTitle : "Chat"));

    private void Unpin(TilePin pin)
    {
        if (_pins == null) return;
        var pins = _pins;
        var index = pins.IndexOf(pin.Id);
        var name = pins.Name(pin);
        pins.Unpin(pin.Id);
        SyncSoon();
        Toast(TileWords.Unpinned(name), () => { pins.Restore(pin, index); SyncSoon(); });
    }

    private async Task ConfirmRemove(TilePin pin, string name)
    {
        if (!await Confirm(TileWords.RemoveTitle(name), TileWords.RemoveMessage, TileWords.RemoveArtifact)) return;
        _hidden?.Hide(pin.Id, _pins);
        SyncSoon();
        Toast(TileWords.Removed);
    }

    private async Task RenameTile(TilePin pin)
    {
        if (_pins == null) return;
        var automatic = pin.NamedByFile ? _pins.Name(pin) : pin.AutomaticName;
        var box = new TextBox { Text = _pins.Name(pin), PlaceholderText = automatic };
        AutomationProperties.SetAutomationId(box, "tile.rename.field");
        var dialog = new ContentDialog
        {
            Title = TileWords.RenameTile, XamlRoot = XamlRoot,
            Content = new StackPanel { Spacing = 10, Children = { Kit.Text(TileWords.RenameMessage(pin), 13, secondary: true), box } },
            PrimaryButtonText = TileWords.RenameAction, CloseButtonText = TileWords.Cancel, DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowDialog(dialog) != ContentDialogResult.Primary) return;
        var typed = box.Text.Trim();
        _pins.Rename(pin.Id, typed == automatic || typed == pin.AutomaticName ? "" : box.Text);
        SyncSoon();
    }

    /// A tile's button (on the Tiles page or in the opened tile): guarded by `TileLiveGuard` (`busy` + 1 s `throttled`),
    /// then delivered to the tile's bot as an acting maker so the tile shows its "Updating…" veil and reloads on finish.
    private void OnWebMessage(TilePin pin, TileWeb.Message m, WebView2 web)
    {
        if (m.Open) { Open(pin); return; }
        if (m.Refresh) { Reread(pin.Id); return; }
        if (m.Id is not { } id) return;
        if (ReadOnlyGateway) { Toast(TileWords.ReadOnly); TileWeb.Ack(web, id, false, "read_only"); return; }

        var decision = _liveGuard.Evaluate(pin.Id, m.Prompt, IsWorkingOn(pin.Id));
        switch (decision.Kind)
        {
            case TileLiveGuard.DecisionKind.Reject:
                TileWeb.Ack(web, id, false, decision.Error);
                return;
            case TileLiveGuard.DecisionKind.Wait:
                _ = WaitAndDeliverAsync(pin, m.Prompt!.Trim(), web, id, decision.Delay);
                return;
            default:
                DeliverLivePrompt(pin, m.Prompt!.Trim(), web, id);
                return;
        }
    }

    private async Task WaitAndDeliverAsync(TilePin pin, string prompt, WebView2 web, int id, TimeSpan delay)
    {
        try { await Task.Delay(delay, _life?.Token ?? CancellationToken.None); }
        catch (OperationCanceledException) { _liveGuard.CancelWait(pin.Id); return; }
        OnUi(() =>
        {
            var next = _liveGuard.CompleteWait(pin.Id, IsWorkingOn(pin.Id));
            if (next.Kind == TileLiveGuard.DecisionKind.Reject)
            {
                TileWeb.Ack(web, id, false, next.Error);
                return;
            }
            DeliverLivePrompt(pin, prompt, web, id);
        });
    }

    private void DeliverLivePrompt(TilePin pin, string prompt, WebView2 web, int id)
    {
        if (_client == null || pin.GatewayPath is not { } path) { Toast(TileWords.CouldntSend); TileWeb.Ack(web, id, false); return; }
        var bot = _bots.FirstOrDefault(b => b.Name == pin.Profile);
        if (bot == null) { Toast(TileWords.BotGone); TileWeb.Ack(web, id, false); return; }
        _ = SendFromTile(pin, path, bot, prompt, web, id);
    }

    private async Task SendFromTile(TilePin pin, string path, Bot bot, string prompt, WebView2 web, int id)
    {
        if (_client == null || _pins == null) return;
        var tileName = _pins.Name(pin);
        OnUi(() => TileWeb.Ack(web, id, true));
        await StartTileMakerAsync(
            bot,
            prompt,
            TileWords.ActionPrompt(path, tileName, prompt),
            displayTitle: $"Updating {tileName}: {prompt}",
            desiredSize: pin.TileSize,
            pageId: _pins.PageId(pin),
            changingPin: pin,
            acting: true,
            customPath: path);
    }

    // ------------------------------------------------------------------ small pieces

    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _toastTimer;

    /// A word over the page's foot for a moment ("Copied", "Moved to Work"), with Undo when there is one.
    private void Toast(string text, Action? undo = null)
    {
        OnUi(() =>
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { Kit.Text(text, 13, wrap: false) } };
            if (undo != null)
            {
                var b = new HyperlinkButton { Content = TileWords.Undo, Padding = new Thickness(4, 0, 4, 0) };
                b.Click += (_, _) => { undo(); _toast.Visibility = Visibility.Collapsed; };
                row.Children.Add(b);
            }
            _toast.Child = row;
            _toast.Visibility = Visibility.Visible;
            AutomationProperties.SetName(_toast, text);
            Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(_toast)?.RaiseNotificationEvent(
                Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationKind.ActionCompleted,
                Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationProcessing.MostRecent, text, "tiles");
            _toastTimer?.Stop();
            _toastTimer = Ui.CreateTimer();
            _toastTimer.Interval = TimeSpan.FromSeconds(undo != null ? 5 : 2);
            _toastTimer.IsRepeating = false;
            _toastTimer.Tick += (_, _) => _toast.Visibility = Visibility.Collapsed;
            _toastTimer.Start();
        });
    }

    private async Task<string?> AskName(string title, string name, string action)
    {
        var box = new TextBox { Text = name, PlaceholderText = "Name" };
        AutomationProperties.SetAutomationId(box, "dashboard.page.name");
        var dialog = new ContentDialog
        {
            Title = title, XamlRoot = XamlRoot, Content = box, PrimaryButtonText = action, CloseButtonText = TileWords.Cancel,
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowDialog(dialog) != ContentDialogResult.Primary) return null;
        return box.Text.Trim();
    }

    private async Task<bool> Confirm(string title, string message, string action)
    {
        var dialog = new ContentDialog
        {
            Title = title, XamlRoot = XamlRoot, Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = action, CloseButtonText = TileWords.Cancel, DefaultButton = ContentDialogButton.Close,
        };
        return await ShowDialog(dialog) == ContentDialogResult.Primary;
    }

    private static Task<ContentDialogResult> ShowDialog(ContentDialog dialog) =>
        SafeDialog.ShowAsync(dialog.XamlRoot, dialog);
}
