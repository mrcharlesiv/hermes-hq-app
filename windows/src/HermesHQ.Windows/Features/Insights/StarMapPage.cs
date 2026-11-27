using Hermes.Core.Composer;
using Hermes.Core.Insights;
using HermesHQ.Controls;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace HermesHQ.Features.Insights;

/// Insights › Star Map (App/Pages/More/StarMap/StarMapPage.swift, StarMapModel.swift; docs/spec/3x-morepages.md §17):
/// what a bot has learned, as a map of stars and as a list. Read-only. The Bot picker, the View switch (Map / List, the
/// choice kept), the count line, the filter menu in the bar (All · Used · Learned, Refresh), the node sheet.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class StarMapPage : InsightsPage, HermesHQ.Shell.IKeyRefreshing
{
    private enum Phase { Loading, Loaded, Failed }

    private const string ModeKey = "pages.more.starmap.view";
    private const uint SpiGetScreenReader = 0x0046;
    private static readonly IKeyValueStore Prefs = new JsonFileStore(Path.Combine(AppPaths.Root, "starmap.json"));

    /// Optional probe override for tests and walks; when null, queries Windows SPI_GETSCREENREADER.
    internal static Func<bool>? ScreenReaderProbe { get; set; }

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint param, ref int value, uint winIni);

    internal static bool IsScreenReaderActive()
    {
        if (ScreenReaderProbe is { } probe) return probe();
        try
        {
            var active = 0;
            return SystemParametersInfo(SpiGetScreenReader, 0, ref active, 0) && active != 0;
        }
        catch (Exception) { return false; }
    }

    private readonly BotPicker _picker = new("star-map");
    private readonly StackPanel _header = new() { Spacing = 6, MaxWidth = Kit.ReadableWidth + 32, Padding = new Thickness(16, 4, 16, 6) };
    private readonly Grid _segments = new() { Height = 28, CornerRadius = new CornerRadius(8) };
    private readonly ToggleButton _mapButton, _listButton;
    private readonly TextBlock _subtitle = Kit.Text("", 12, secondary: true);
    private readonly Grid _refreshFailed = new() { ColumnSpacing = 12 };
    private readonly Border _content = new();
    private readonly StarMapCanvas _map;
    private readonly Button _filterButton;
    private readonly FontIcon _filterGlyph = new() { Glyph = "", FontSize = 15 };
    private readonly MenuFlyout _filterMenu = new();

    private Phase _phase = Phase.Loading;
    private string _reason = "";
    private StarMapGraph? _graph;
    private StarMapShown _shown = new();
    private Dictionary<string, StarMapNode> _nodes = [];
    private StarMapFilter _filter = StarMapFilter.All;
    private bool _listMode;
    private bool _refreshFailedShown;
    private bool _manyBots;
    private string _profile = "default";
    private int _generation, _loadGeneration;
    private CancellationTokenSource? _load;
    private bool _sheetOpen;

    // [WIN-STAR-FIRST] What the star-map-first-open walk reads (Services/ProofWalks.StarMapFirstOpen.cs): the page on
    // show, its graph reads and its retries since it was built, and what it has on show.
    public static StarMapPage? Current { get; private set; }
    public int GraphReads { get; private set; }
    public int Retries { get; private set; }
    public string PhaseWord => _phase switch { Phase.Loaded => "loaded", Phase.Failed => "failed", _ => "loading" };
    public string Profile => _profile;
    public int ShownSkills => _shown.Skills;
    public int ShownCards => _shown.Memory.Count;
    public int ShownStars => _shown.Layout.Stars.Count;
    public int ShownEdges => _shown.Layout.Edges.Count;
    public int DrawnStars => _map.DrawnStars;
    public int DrawnEdges => _map.DrawnEdges;
    /// The Map's fly-in has ended (or never ran).
    public bool MapSettled => _map.Settled;

    public StarMapPage()
    {
        _map = new StarMapCanvas(Open);
        // Screen reader active: open in List view without overwriting the saved Map preference.
        _listMode = StarMapViewRules.InitialListMode(Prefs.Get(ModeKey), IsScreenReaderActive());

        _mapButton = Segment("Map", () => SetMode(list: false));
        _listButton = Segment("List", () => SetMode(list: true));
        _segments.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _segments.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        AutomationProperties.SetAutomationId(_mapButton, "starmap.mode.map");
        AutomationProperties.SetAutomationId(_listButton, "starmap.mode.list");
        _segments.Children.Add(_mapButton);
        Grid.SetColumn(_listButton, 1);
        _segments.Children.Add(_listButton);
        _segments.Background = Kit.Brush("ControlFillColorSecondaryBrush");
        AutomationProperties.SetName(_segments, "View");
        AutomationProperties.SetAutomationId(_segments, "starmap.mode");
        AutomationProperties.SetAutomationId(_subtitle, "starmap.subtitle");

        var failedText = Kit.Text("Couldn’t refresh. Showing the last map.", 13, secondary: true);
        failedText.VerticalAlignment = VerticalAlignment.Center;
        var failedRetry = new Button { Content = InsightsWire.TryAgain };
        failedRetry.Click += (_, _) => Retry();
        _refreshFailed.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _refreshFailed.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _refreshFailed.Children.Add(failedText);
        Grid.SetColumn(failedRetry, 1);
        _refreshFailed.Children.Add(failedRetry);
        AutomationProperties.SetAutomationId(_refreshFailed, "starmap.refresh-failed");

        _picker.Margin = new Thickness(0, 0, 0, 4);
        _picker.Visibility = Visibility.Collapsed;
        _picker.Changed += ProfileChanged;
        _header.Children.Add(_picker);
        _header.Children.Add(_segments);
        _header.Children.Add(_subtitle);
        _header.Children.Add(_refreshFailed);

        var page = new Grid();
        page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        page.Children.Add(_header);
        Grid.SetRow(_content, 1);
        page.Children.Add(_content);
        SetBody(page);

        // The filter menu: the choices (All · Used · Learned), then Refresh.
        foreach (var f in StarMapFilters.AllCases)
        {
            var item = new RadioMenuFlyoutItem { Text = f.Title(), GroupName = "starmap-filter", Tag = f };
            item.Click += (_, _) => SetFilter(f);
            _filterMenu.Items.Add(item);
        }
        _filterMenu.Items.Add(new MenuFlyoutSeparator());
        var refresh = new MenuFlyoutItem { Text = "Refresh", Icon = new FontIcon { Glyph = "" } };
        refresh.Click += (_, _) => Retry();
        _filterMenu.Items.Add(refresh);
        _filterButton = Kit.BarButton("", "Filter", () => { });
        _filterButton.Content = _filterGlyph;
        _filterButton.Flyout = _filterMenu;
        AutomationProperties.SetAutomationId(_filterButton, "starmap.filter");
        BarActions.Children.Add(_filterButton);

        KeyboardAcceleratorPlacementMode = Microsoft.UI.Xaml.Input.KeyboardAcceleratorPlacementMode.Hidden;
        KeyboardAccelerators.Add(Accelerator(Windows.System.VirtualKey.R, Retry));   // Ctrl+R, the Mac's ⌘R
        Render();
    }

    private static Microsoft.UI.Xaml.Input.KeyboardAccelerator Accelerator(Windows.System.VirtualKey key, Action run)
    {
        var a = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = key, Modifiers = Windows.System.VirtualKeyModifiers.Control };
        a.Invoked += (_, e) => { run(); e.Handled = true; };
        return a;
    }

    private static ToggleButton Segment(string title, Action pick)
    {
        var b = new ToggleButton
        {
            Content = title, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch,
            FontSize = 12, FontWeight = FontWeights.SemiBold, Padding = new Thickness(0), CornerRadius = new CornerRadius(7),
            BorderThickness = new Thickness(0), Margin = new Thickness(2),
        };
        b.Click += (_, _) => pick();
        return b;
    }

    // ------------------------------------------------------------------ the model (StarMapModel)

    protected override void Shown()
    {
        Current = this;
        if (Client is not { } client) return;
        _ = StartAsync(client);
    }

    protected override void Hidden()
    {
        if (Current == this) Current = null;
        _load?.Cancel();
        _load = null;
    }

    private async Task StartAsync(Hermes.Core.HermesClient client)
    {
        try
        {
            var bots = client.Bots ?? await client.BotsAsync();
            _profile = _picker.SetBots(bots, client.AccountId);
            _manyBots = bots.Count > 1;
        }
        catch (Exception) { _profile = "default"; }
        if (_graph == null) Load(); else Render();
    }

    /// View › Refresh (Ctrl+R, F5): as its own Ctrl+R and its Refresh button.
    public void KeyRefresh() => Retry();

    private void Retry()
    {
        Retries++;
        if (_graph == null) { _phase = Phase.Loading; Render(); }
        Load();
    }

    /// Reads the graph again. With a graph on show a failure keeps it (offline: the page keeps its data).
    private void Load()
    {
        if (Client is not { } client) return;
        _load?.Cancel();
        var cts = _load = new CancellationTokenSource();
        var profile = _profile;
        var filter = _filter;
        var mine = ++_loadGeneration;
        GraphReads++;
        if (_graph == null) { _phase = Phase.Loading; Render(); }
        _ = Task.Run(async () =>
        {
            try
            {
                var graph = await StarMapApi.GraphAsync(client.Session, profile, cts.Token);
                AppLog.Note("starmap", $"graph: {graph.Nodes.Count} nodes, {graph.Edges.Count} edges, {graph.Memory.Count} cards");
                var shown = StarMapShown.Make(graph, filter, 0);
                OnUi(() =>
                {
                    if (cts.IsCancellationRequested || mine != _loadGeneration || profile != _profile) return;
                    if (filter != _filter) shown = StarMapShown.Make(graph, _filter, 0);
                    Take(graph, shown);
                });
            }
            catch (Exception e)
            {
                if (cts.IsCancellationRequested) return;
                var reason = InsightsWire.Reason(e);
                AppLog.Note("starmap", $"graph failed: {InsightsWire.Scrubbed(reason)}");
                OnUi(() =>
                {
                    if (mine != _loadGeneration || profile != _profile) return;
                    if (_graph != null) { _refreshFailedShown = true; Render(); return; }
                    _phase = Phase.Failed;
                    _reason = reason;
                    Render();
                });
            }
        });
    }

    private void Take(StarMapGraph graph, StarMapShown shown)
    {
        _graph = graph;
        _refreshFailedShown = false;
        _nodes = [];
        foreach (var n in graph.Nodes) _nodes.TryAdd(n.Id, n);
        _shown = WithGeneration(shown, ++_generation);
        _phase = Phase.Loaded;
        Render();
    }

    private static StarMapShown WithGeneration(StarMapShown s, int generation) => new()
    {
        Sections = s.Sections, Memory = s.Memory, Layout = s.Layout, Subtitle = s.Subtitle, Skills = s.Skills, Generation = generation,
    };

    private void SetFilter(StarMapFilter f)
    {
        if (f == _filter) return;
        _filter = f;
        if (_graph is not { } graph) { Render(); return; }
        var generation = ++_generation;
        _ = Task.Run(() =>
        {
            var shown = StarMapShown.Make(graph, f, generation);
            OnUi(() =>
            {
                if (generation != _generation) return;
                _shown = shown;
                Render();
            });
        });
    }

    private void SetMode(bool list)
    {
        _listMode = list;
        Prefs.Set(ModeKey, list ? "list" : "map");
        Render();
    }

    private void ProfileChanged(string profile)
    {
        if (profile == _profile) return;
        _profile = profile;
        _refreshFailedShown = false;
        _graph = null;
        _nodes = [];
        _shown = new StarMapShown();
        _phase = Phase.Loading;
        Load();
    }

    private bool HasGraph => _phase == Phase.Loaded && _graph is { IsEmpty: false };
    private bool IsUnavailable => _phase == Phase.Failed && _reason == InsightsWire.OlderHermes;
    private bool FilterMiss => _filter != StarMapFilter.All && _graph is { IsEmpty: false } && _shown.Layout.Stars.Count == 0;

    // ------------------------------------------------------------------ drawing the page

    private void Render()
    {
        var hasGraph = HasGraph;
        // No Bot picker over "Not Available on This Hermes".
        _picker.Visibility = _manyBots && !IsUnavailable ? Visibility.Visible : Visibility.Collapsed;
        _segments.Visibility = _subtitle.Visibility = hasGraph ? Visibility.Visible : Visibility.Collapsed;
        _refreshFailed.Visibility = hasGraph && _refreshFailedShown ? Visibility.Visible : Visibility.Collapsed;
        _subtitle.Text = _shown.Subtitle;
        _mapButton.IsChecked = !_listMode;
        _listButton.IsChecked = _listMode;
        // The filter glyph shows only with a graph to filter, filled while a filter is on.
        _filterButton.Visibility = hasGraph ? Visibility.Visible : Visibility.Collapsed;
        _filterGlyph.Glyph = _filter == StarMapFilter.All ? "" : "";
        AutomationProperties.SetItemStatus(_filterButton, _filter.Title());
        foreach (var item in _filterMenu.Items.OfType<RadioMenuFlyoutItem>()) item.IsChecked = (StarMapFilter)item.Tag == _filter;

        switch (_phase)
        {
            case Phase.Loading:
                _content.Child = Kit.Loading(retry: Retry);
                break;
            case Phase.Failed:
                _content.Child = Kit.Error("Couldn’t Load Star Map", _reason, Retry, unavailableGlyph: "");
                AutomationProperties.SetAutomationId(_content.Child, IsUnavailable ? "starmap.unavailable" : "starmap.error");
                break;
            default:
                if (_graph is { IsEmpty: true })
                {
                    _content.Child = Kit.Empty("", "Nothing Learned Yet", "As Hermes builds skills and memories for your work, they appear here.");
                    AutomationProperties.SetAutomationId(_content.Child, "starmap.empty");
                }
                else if (FilterMiss)
                {
                    var all = new Button { Content = "Show All", Style = Kit.Style("AccentButtonStyle") };
                    all.Click += (_, _) => SetFilter(StarMapFilter.All);
                    _content.Child = Kit.Empty("", $"No {_filter.Title()} Skills", "Nothing here matches this filter yet.", all);
                    AutomationProperties.SetAutomationId(_content.Child, "starmap.filter-miss");
                }
                else if (!_listMode)
                {
                    if (_content.Child != _map) _content.Child = _map;
                    _map.Show(_shown.Layout, _shown.Generation);
                }
                else _content.Child = List();
                break;
        }
    }

    // ------------------------------------------------------------------ the List (StarMapList)

    private FrameworkElement List()
    {
        var scroll = Kit.Column(out var column);
        AutomationProperties.SetAutomationId(scroll, "starmap.list");
        foreach (var section in _shown.Sections)
            column.Children.Add(Kit.Section(section.Header, section.Nodes.Select(n => (UIElement)Row(n)).ToList()));
        if (_shown.Memory.Count > 0)
            column.Children.Add(Kit.Section("Memory", _shown.Memory.Select(c => (UIElement)MemoryRow(c)).ToList()));
        return scroll;
    }

    private FrameworkElement Row(StarMapNode n)
    {
        UIElement? pin = null;
        if (n.Pinned)
        {
            var icon = new FontIcon { Glyph = "", FontSize = 12, Foreground = Kit.Brush("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(icon, "Pinned");
            pin = icon;
        }
        var row = Kit.Row(n.Label, detail: StarMapRules.UsedLine(n.UseCount), trailing: pin, open: () => Open(n.Id));
        AutomationProperties.SetAutomationId(row, $"starmap.row.{n.Id}");
        return row;
    }

    /// A memory card: its title and its text, folded at 4 lines until Show More.
    private static FrameworkElement MemoryRow(StarMapMemoryCard card)
    {
        var panel = new StackPanel { Spacing = 6, Padding = new Thickness(16, 10, 16, 10) };
        TextBlock? title = null, body = null;
        if (card.Title.Length > 0)
        {
            title = Kit.Text(card.Title, 14, bold: true);
            title.MaxLines = 2;
            title.TextTrimming = TextTrimming.CharacterEllipsis;
            panel.Children.Add(title);
        }
        if (card.Body.Length > 0 && card.Body != card.Title)
        {
            body = Kit.Text(card.Body, 13, secondary: true);
            body.MaxLines = 4;
            body.TextTrimming = TextTrimming.CharacterEllipsis;
            panel.Children.Add(body);
        }
        if (StarMapRules.Folds(card.Body))
        {
            var open = false;
            var more = new HyperlinkButton { Content = "Show More", Padding = new Thickness(0), FontSize = 13 };
            AutomationProperties.SetAutomationId(more, $"starmap.memory.more.{card.Id}");
            more.Click += (_, _) =>
            {
                open = !open;
                more.Content = open ? "Show Less" : "Show More";
                if (title != null) title.MaxLines = open ? 0 : 2;
                if (body != null) body.MaxLines = open ? 0 : 4;
            };
            panel.Children.Add(more);
        }
        return panel;
    }

    // ------------------------------------------------------------------ the node sheet (StarMapNodeSheet)

    private void Open(string id)
    {
        if (!_nodes.TryGetValue(id, out var node) || _sheetOpen || XamlRoot == null || Client is not { } client) return;
        _ = ShowSheetAsync(node, client, _profile);
    }

    /// What a star says: its tags and quiet line from the graph, and its text from `/api/learning/node` (its front
    /// matter left out, the Markdown drawn). Closes with Done.
    private async Task ShowSheetAsync(StarMapNode node, Hermes.Core.HermesClient client, string profile)
    {
        _sheetOpen = true;
        var words = new StackPanel { Spacing = 10 };
        var card = new Border
        {
            Child = words, Padding = new Thickness(16), CornerRadius = new CornerRadius(10),
            Background = Kit.Brush("CardBackgroundFillColorDefaultBrush"), BorderBrush = Kit.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
        };
        var tagWords = StarMapRules.Tags(node);
        var tags = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var t in tagWords)
            tags.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(11), Padding = new Thickness(10, 3, 10, 4), Background = Kit.Brush("ControlFillColorSecondaryBrush"),
                Child = new TextBlock { Text = t, FontSize = 12, FontWeight = FontWeights.Medium },
            });
        AutomationProperties.SetName(tags, string.Join(", ", tagWords));
        AutomationProperties.SetAutomationId(tags, "starmap.node.tags");
        var column = new StackPanel { Spacing = 10 };
        column.Children.Add(tags);
        var quiet = StarMapRules.QuietLine(node);
        if (quiet.Length > 0)
        {
            var line = Kit.Text(quiet, 12, secondary: true);
            AutomationProperties.SetAutomationId(line, "starmap.node.line");
            column.Children.Add(line);
        }
        column.Children.Add(card);

        var title = new TextBlock { Text = node.Label, FontSize = 20, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
        AutomationProperties.SetAutomationId(title, "starmap.node.title");
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = title, CloseButtonText = "Done", DefaultButton = ContentDialogButton.Close,
            Content = new ScrollViewer { Content = column, MaxHeight = 520, HorizontalScrollMode = ScrollMode.Disabled },
        };
        AutomationProperties.SetAutomationId(dialog, "starmap.node");
        var cts = new CancellationTokenSource();

        async Task Read()
        {
            words.Children.Clear();
            var loading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            loading.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            loading.Children.Add(Kit.Text("Loading…", 13, secondary: true));
            AutomationProperties.SetAutomationId(loading, "starmap.node.loading");
            words.Children.Add(loading);
            try
            {
                var detail = await Task.Run(() => StarMapApi.NodeAsync(client.Session, node.Id, profile, cts.Token));
                if (cts.IsCancellationRequested) return;
                words.Children.Clear();
                var body = new StackPanel { Spacing = 6 };
                AutomationProperties.SetAutomationId(body, "starmap.node.text");
                MarkdownRenderer.Render(StarMapNodeDetail.StripFrontMatter(detail.Content), body);
                words.Children.Add(body);
            }
            catch (Exception e)
            {
                if (cts.IsCancellationRequested) return;
                words.Children.Clear();
                if (StarMapApi.IsMissing(e))
                {
                    var missing = Kit.Text("This is no longer in the map.", 13, secondary: true);
                    AutomationProperties.SetAutomationId(missing, "starmap.node.missing");
                    words.Children.Add(missing);
                }
                else
                {
                    var failed = Kit.Text("Couldn’t load this.", 13, secondary: true);
                    AutomationProperties.SetAutomationId(failed, "starmap.node.failed");
                    var retry = new Button { Content = InsightsWire.TryAgain };
                    AutomationProperties.SetAutomationId(retry, "starmap.node.retry");
                    retry.Click += (_, _) => _ = Read();
                    words.Children.Add(failed);
                    words.Children.Add(retry);
                }
            }
        }

        _ = Read();
        try { await dialog.ShowAsync(); }
        catch (Exception) { /* another dialog is up */ }
        finally
        {
            cts.Cancel();
            _sheetOpen = false;
        }
    }
}
