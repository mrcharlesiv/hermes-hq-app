using Hermes.Core.Jobs;
using Hermes.Core.QuickActions;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Jobs;
using HermesHQ.Features.Kanban;
using HermesHQ.Features.OpenQuickly;
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
using Windows.UI;

namespace HermesHQ.Features.QuickActions;

/// The Quick Actions (Favorites) page (QuickActionsViewController.swift): tiles in two columns, Small or Wide and Tall
/// or Short (Wide + Short = compact banner strip, Small + Tall = vertical tile); one click runs one (QuickActionsRouter.run).
/// Edit removes (−), resizes with the blue corner drag/click handle, reorders (Move Up / Move Down) and adds (＋ Add Action);
/// right-clicking a tile out of Edit offers Small, Wide, Tall, Short, Edit… and Remove.
/// On wide panes (including Ctrl+Shift+K) or when presented via `ShowSheetAsync`, the grid is framed as a centered
/// modal/sheet (~478–504 DIP wide, matching Mac's 478 × 441 sheet proportions).
/// [WIN-QUICK-GRID] The grid follows the page's width and Windows' text size (QuickTileLayout): one full-width column
/// at accessibility text sizes, the side 16 up to a 700-wide page and 24 past it, the words wrapping instead of cut.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class QuickActionsPage : Page
{
    public const double SheetWidth = 496;
    public const double SheetMinHeight = 441;

    private QuickTileList _list = new();
    private bool _editing, _seeding;
    private readonly bool _inSheet;
    private readonly Action? _dismissSheet;
    private readonly StackPanel _grid = new();
    private readonly ScrollViewer _scroll = new() { HorizontalScrollMode = ScrollMode.Disabled };
    private readonly Border _sheetFrame;
    /// Kept for its TextScaleFactorChanged (a UISettings let go of stops raising it).
    private readonly Windows.UI.ViewManagement.UISettings _ui = new();
    private (bool Stacked, double Side, double Gap)? _drawnKey;
    /// The tile a menu's Move Up / Down or Small / Wide acted on: the keyboard goes back to it once redrawn.
    private string? _focusAfter;
    private readonly Button _edit = new() { Content = "Edit" };
    private readonly NoticeLine _notice = new();
    private CancellationTokenSource? _seedWait;

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
        // [WIN-50] The Mac's page bar (MacWindow.pageBar, Shell/PageBar.cs): the page-title token and the page's side;
        // Edit at the edge (QuickActionsViewController.swift: [editItem] once there are tiles).
        var bar = new Grid { Padding = inSheet ? new Thickness(16, 12, 16, 6) : HermesHQ.Shell.PageBar.Padding(12, 4), ColumnSpacing = 10 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new TextBlock { Text = pageTitle, VerticalAlignment = VerticalAlignment.Center };
        HermesHQ.Shell.PageBar.Title(title, "quick-actions");
        bar.Children.Add(title);
        Grid.SetColumn(_edit, 1);
        bar.Children.Add(_edit);
        var scroll = _scroll;
        scroll.Content = _grid;
        AutomationProperties.SetAutomationId(scroll, "quick-actions.grid");
        // A resize redraws only when it moves the plan (the side past 700); the tiles otherwise stretch as they are.
        scroll.SizeChanged += (_, _) => { if (_drawnKey != Key()) Draw(); };
        var sheetBody = new Grid();
        sheetBody.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        sheetBody.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(scroll, 1);
        Grid.SetRow(_notice.Bar, 1);
        sheetBody.Children.Add(bar);
        sheetBody.Children.Add(scroll);
        sheetBody.Children.Add(_notice.Bar);

        _sheetFrame = new Border
        {
            Child = sheetBody,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
        };
        var outer = new Grid { Children = { _sheetFrame } };
        SizeChanged += (_, e) => ApplySheetPresentation(e.NewSize.Width, e.NewSize.Height);
        Content = outer;
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

    private ListsHub? _hub;

    internal void ActivateSheet()
    {
        if (_hub != null) _hub.Changed -= Reload;
        _hub = ListsHub.Current;
        if (_hub != null) _hub.Changed += Reload;
        _ui.TextScaleFactorChanged -= TextScaleChanged;
        _ui.TextScaleFactorChanged += TextScaleChanged;
        AppLog.Note("quick-actions", "open sheet");
        LoadList();
    }

    internal void DeactivateSheet()
    {
        if (_hub != null) { _hub.Changed -= Reload; _hub = null; }
        _ui.TextScaleFactorChanged -= TextScaleChanged;
        _seedWait?.Cancel();
        _editing = false;
    }

    /// On desktop widths, frames the Favorites page as a centered sheet card (~496 DIP wide) so tiles match Mac's
    /// 478 × 441 sheet proportions rather than stretching edge-to-edge across an 1160+ px pane.
    private void ApplySheetPresentation(double width, double height)
    {
        if (_inSheet) return;
        var centered = !QuickTileLayout.StackedAt(TextScale()) && width > SheetWidth + 64;
        if (centered)
        {
            _sheetFrame.MaxWidth = SheetWidth;
            _sheetFrame.MinHeight = Math.Min(SheetMinHeight, Math.Max(200, height - 48));
            _sheetFrame.MaxHeight = Math.Max(SheetMinHeight, height - 48);
            _sheetFrame.HorizontalAlignment = HorizontalAlignment.Center;
            _sheetFrame.VerticalAlignment = VerticalAlignment.Center;
            _sheetFrame.CornerRadius = new CornerRadius(14);
            _sheetFrame.Background = PageKit.Brush("SolidBackgroundFillColorBaseBrush");
            _sheetFrame.BorderBrush = PageKit.Brush("CardStrokeColorDefaultBrush");
            _sheetFrame.BorderThickness = new Thickness(1);
            _sheetFrame.Margin = new Thickness(24);
        }
        else
        {
            _sheetFrame.MaxWidth = double.PositiveInfinity;
            _sheetFrame.MinHeight = 0;
            _sheetFrame.MaxHeight = double.PositiveInfinity;
            _sheetFrame.HorizontalAlignment = HorizontalAlignment.Stretch;
            _sheetFrame.VerticalAlignment = VerticalAlignment.Stretch;
            _sheetFrame.CornerRadius = new CornerRadius(0);
            _sheetFrame.Background = null;
            _sheetFrame.BorderBrush = null;
            _sheetFrame.BorderThickness = new Thickness(0);
            _sheetFrame.Margin = new Thickness(0);
        }
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (_hub != null) _hub.Changed -= Reload;
        _hub = ListsHub.Current;
        if (_hub != null) _hub.Changed += Reload;
        _ui.TextScaleFactorChanged -= TextScaleChanged;
        _ui.TextScaleFactorChanged += TextScaleChanged;
        AppLog.Note("quick-actions", "open");
        LoadList();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        if (_hub != null) { _hub.Changed -= Reload; _hub = null; }
        _ui.TextScaleFactorChanged -= TextScaleChanged;
        _seedWait?.Cancel();
        _editing = false;
    }

    // ------------------------------------------------------------------ the list

    /// The stored list, or the starter set the first time there's a bot to make it for (the roster may still be on
    /// its way: up to 6 s, as the Mac).
    private void LoadList()
    {
        _list = QuickTileStore.Load(QuickActionsFeature.Store);
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
        Reload();
    }

    private void Reload()
    {
        var stored = QuickTileStore.Load(QuickActionsFeature.Store);
        if (stored.Seeded || stored.Tiles.Count > 0) _list = stored;
        if (_list.Tiles.Count == 0) _editing = false;
        _edit.Content = _editing ? "Done" : "Edit";
        if (_editing) _edit.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        else _edit.ClearValue(StyleProperty);
        _edit.Visibility = _list.Tiles.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        Draw();
    }

    // ------------------------------------------------------------------ the grid (QuickTileLayout)

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
            ApplySheetPresentation(ActualWidth, ActualHeight);
            if (_drawnKey != Key()) Draw();
        });
    }

    /// The tiles (and ＋ while editing) laid out for the page's width and text size, in the list's order. The tile that
    /// had the keyboard keeps it: it is found again by its automation id (`quick-tile-<id>`, `quick-actions.add-tile`,
    /// `quick-actions.empty.add`), which a redraw never changes.
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
        _drawnKey = Key();
        _grid.Children.Clear();
        if (_list.Tiles.Count == 0)
        {
            _grid.Padding = new Thickness(0);
            if (!_seeding) _grid.Children.Add(Empty());
            Refocus(focusId, focusState);
            return;
        }
        var world = World();
        var cells = _list.Tiles.ToList();
        var addIndex = -1;
        if (_editing) { addIndex = cells.Count; cells.Add(QuickTile.Create(QuickTileKind.Page, id: "quick-actions.add")); }
        var plan = QuickTileLayout.Fit(cells, _scroll.ActualWidth, TextScale());
        _grid.Spacing = plan.Gap;
        _grid.Padding = new Thickness(plan.Side, plan.Top, plan.Side, plan.Bottom);
        foreach (var row in plan.Rows)
        {
            var line = new Grid { ColumnSpacing = plan.Gap };
            for (var c = 0; c < row.Columns; c++)
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            foreach (var slot in row.Slots)
            {
                FrameworkElement cell = slot.Index == addIndex ? AddTile(plan) : Tile(cells[slot.Index], world, plan);
                Grid.SetColumn(cell, slot.Column);
                Grid.SetColumnSpan(cell, slot.Span);
                line.Children.Add(cell);
            }
            _grid.Children.Add(line);
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

    /// The CURRENT gateway's bots, jobs and pages (null where they aren't known yet: never "missing").
    private static QuickTileWorld World()
    {
        var hub = ListsHub.Current;
        var bots = hub != null && hub.Bots.HasRoster
            ? hub.Bots.Rows.GroupBy(r => r.Id).ToDictionary(g => g.Key, g => g.First().Model.DisplayName)
            : null;
        var store = JobsServices.Store;
        return new QuickTileWorld(Bots: bots, Jobs: QuickTileRun.WorldJobs(KnownJobs(store), store?.Scope ?? "all"),
            Pages: PageChoices().ToDictionary(p => p.Id, p => p.Title));
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
        // At accessibility text sizes the Mac leaves the picture out (PageStates.empty, `isAccessibilityCategory`); the
        // words wrap, centred, inside the page's side.
        var side = QuickTileLayout.Key(_scroll.ActualWidth, TextScale()).Side;
        var panel = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(side, 80, side, 0) };
        if (!QuickTileLayout.StackedAt(TextScale()))
            panel.Children.Add(new FontIcon { Glyph = "\uE734", FontSize = 40, Foreground = PageKit.Secondary });
        panel.Children.Add(new TextBlock { Text = "No Favorites", FontSize = 20, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.WrapWholeWords });
        panel.Children.Add(new TextBlock { Text = "Add the actions and pages you use most.", Foreground = PageKit.Secondary, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.WrapWholeWords });
        var add = new Button { Content = "Add Action", Style = (Style)Application.Current.Resources["AccentButtonStyle"], HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
        AutomationProperties.SetAutomationId(add, "quick-actions.empty.add");
        add.Click += (_, _) => _ = ShowAddAsync();
        panel.Children.Add(add);
        AutomationProperties.SetAutomationId(panel, "quick-actions.empty");
        return panel;
    }

    /// A tile (QuickTileFace): Tall tiles stack icon over two-line-reserved name and subtitle; Short tiles (including
    /// Wide+Short Banner strips) lay icon beside single-line name and subtitle; stacked (accessibility sizes) lays words
    /// beside the icon up to eight lines each. In Edit mode, carries a red − remove badge and blue corner resize handle.
    private FrameworkElement Tile(QuickTile tile, QuickTileWorld world, QuickTileLayoutPlan plan)
    {
        var missing = QuickTileRules.Missing(tile, world, QuickTileRules.Windows);
        var subtitle = tile.Subtitle(BotName(tile.Bot));
        var isShort = tile.Short && !plan.Stacked;
        var horizontal = plan.Stacked || isShort;
        var iconSide = isShort ? 30 : 36;
        var icon = new Border
        {
            Width = iconSide, Height = iconSide, CornerRadius = new CornerRadius(isShort ? 7 : 8), Background = TileBrush(tile.Tint),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = horizontal ? VerticalAlignment.Center : VerticalAlignment.Top,
            Child = new FontIcon { Glyph = Glyph(tile.Symbol), FontSize = isShort ? 15 : 18, Foreground = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255)) },
        };
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
        var button = new Button
        {
            Content = face, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
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
        if (!_editing) return button;

        // Edit's − badge over top-left and blue corner resize handle over bottom-right.
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
            AutomationProperties.SetName(resize, tile.Wide ? $"Make {tile.Name} Small" : $"Make {tile.Name} Wide");
            WireResizeHandle(resize, holder, tile);
            holder.Children.Add(resize);
        }
        return holder;
    }

    /// Wires Edit's blue corner resize handle for both click (Small ↔ Wide) and drag (horizontal Small/Wide, vertical Short/Tall).
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
            // Mac QuickActionsViewController.resizeDrag thresholds.
            var wide = startWide ? dx > -startW * 0.25 : dx > startW * 0.3;
            var isShort = startShort ? dy < startH * 0.3 : dy < -startH * 0.3;
            SetDimensions(id, wide, isShort);
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
            SetWide(id, !tile.Wide);
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
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch, Padding = new Thickness(0), Background = null, BorderThickness = new Thickness(0),
        };
        AutomationProperties.SetAutomationId(button, "quick-actions.add-tile");
        AutomationProperties.SetName(button, "Add Action");
        button.Click += (_, _) => _ = ShowAddAsync();
        return button;
    }

    /// Out of Edit: the Mac's hold menu (Small, Wide | Tall, Short | Edit…, Remove). In Edit: the Mac's VoiceOver
    /// actions on a tile (Edit, Remove, Move Up, Move Down, Make Wide / Small, Make Short / Tall).
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
        if (!_editing)
        {
            var small = new RadioMenuFlyoutItem { Text = "Small", GroupName = "size", IsChecked = !tile.Wide };
            small.Click += (_, _) => { _focusAfter = "quick-tile-" + id; SetWide(id, false); };
            var wide = new RadioMenuFlyoutItem { Text = "Wide", GroupName = "size", IsChecked = tile.Wide };
            wide.Click += (_, _) => { _focusAfter = "quick-tile-" + id; SetWide(id, true); };
            menu.Items.Add(small);
            menu.Items.Add(wide);
            menu.Items.Add(new MenuFlyoutSeparator());
            var tall = new RadioMenuFlyoutItem { Text = "Tall", GroupName = "height", IsChecked = !tile.Short };
            tall.Click += (_, _) => { FocusTileAfter(id); SetShort(id, false); };
            var shortItem = new RadioMenuFlyoutItem { Text = "Short", GroupName = "height", IsChecked = tile.Short };
            shortItem.Click += (_, _) => { FocusTileAfter(id); SetShort(id, true); };
            menu.Items.Add(tall);
            menu.Items.Add(shortItem);
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Item("Edit…", "\uE9E9", () => _ = ShowSetupAsync(tile, isNew: false)));
            menu.Items.Add(Item("Remove", "\uE738", () => Remove(id)));
            return menu;
        }
        menu.Items.Add(Item("Edit", "\uE9E9", () => _ = ShowSetupAsync(tile, isNew: false)));
        menu.Items.Add(Item("Remove", "\uE738", () => Remove(id)));
        var index = _list.Tiles.ToList().FindIndex(t => t.Id == id);
        if (index > 0) menu.Items.Add(Item("Move Up", "\uE74A", () => { _focusAfter = "quick-tile-" + id; Step(id, -1); }));
        if (index >= 0 && index < _list.Tiles.Count - 1) menu.Items.Add(Item("Move Down", "\uE74B", () => { _focusAfter = "quick-tile-" + id; Step(id, 1); }));
        menu.Items.Add(Item(tile.Wide ? "Make Small" : "Make Wide", tile.Wide ? "\uE73F" : "\uE740", () => { _focusAfter = "quick-tile-" + id; SetWide(id, !tile.Wide); }));
        menu.Items.Add(Item(tile.Short ? "Make Tall" : "Make Short", tile.Short ? "\uE740" : "\uE73F", () => { FocusTileAfter(id); SetShort(id, !tile.Short); }));
        return menu;
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

    private void SetWide(string id, bool wide) => Change(l => l.SetWide(id, wide));

    private void SetShort(string id, bool isShort) => Change(l =>
    {
        if (l.Tiles.FirstOrDefault(t => t.Id == id) is { } tile && tile.Short != isShort)
            l.Replace(tile with { Short = isShort });
    });

    private void SetDimensions(string id, bool wide, bool isShort) => Change(l =>
    {
        if (l.Tiles.FirstOrDefault(t => t.Id == id) is { } tile && (tile.Wide != wide || tile.Short != isShort))
            l.Replace(tile with { Wide = wide, Short = isShort });
    });

    private void Step(string id, int delta)
    {
        var moved = false;
        Change(l => moved = l.Step(id, delta));
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
                string? chatId = null;
                if (XamlRoot != null && await Prompts.RunAsync(XamlRoot, "Couldn’t Start a New Chat", async () => chatId = await hub.Sessions.NewChatAsync(n.Bot, n.Project))
                    && chatId != null)
                {
                    _dismissSheet?.Invoke();
                    Navigator.Go(new ChatDestination(n.Bot, chatId, "New Chat", n.Message ?? ""));
                }
                break;
            case QuickTileRoute.SendInBackground s:
                if (AppState.Client is not { } client || hub == null)
                {
                    Say(new QuickTileSaid.Failed("Open Hermes HQ once so it knows your bots, then run the shortcut again."));
                    break;
                }
                var sendTo = BotName(s.Profile) ?? tile.BotName ?? s.Profile;
                var sent = await QuickTileRun.SendInBackgroundAsync(client, s.Profile, sendTo, ct => hub.Bots.BotChatIdAsync(s.Profile, ct), s.Words);
                AppLog.Note("quick-actions", sent is QuickTileSaid.Done ? "send: sent" : "send: failed");
                Say(sent);
                break;
            case QuickTileRoute.SendInChat s:
                if (hub?.Bots.Bot(s.Profile) is not { } sendRow)
                {
                    await NoticeAsync($"Hermes HQ has no bot named “{s.Profile}”.", "Couldn’t Start a New Chat");
                    break;
                }
                string? botChat = null;
                try { botChat = await hub.Bots.BotChatIdAsync(s.Profile); }
                catch (Exception x) when (x is not OperationCanceledException) { /* opening the chat says why */ }
                _dismissSheet?.Invoke();
                Navigator.Go(new BotChatDestination(sendRow.Model));
                if (botChat == null) break;
                if (!await QuickTileRun.DeliverAsync(() => QuickActionsFeature.SendInOpenChat(s.Profile, botChat, s.Words)))
                    AppLog.Note("quick-actions", "send in bot chat: the chat never came up for its words");
                break;
            case QuickTileRoute.RunJob r:
                var jobs = JobsServices.Store;
                var target = QuickTileRun.Job(r.Key, jobs?.Scope == "all" ? KnownJobs(jobs) : null);
                if (target is not { } job || (jobs?.Api ?? (AppState.Client is { } c ? new JobsApi(c.Session) : null)) is not { } api)
                {
                    Say(new QuickTileSaid.Failed($"“{r.Name}” isn’t on this gateway."));
                    break;
                }
                var ran = await QuickTileRun.RunJobAsync(api, job.Owner, job.Id, r.Name);
                AppLog.Note("quick-actions", ran is QuickTileSaid.Done ? "run job: started" : "run job: refused");
                Say(ran);
                if (jobs != null) _ = jobs.RefreshAsync();
                break;
            case QuickTileRoute.OpenChat o:
                if (hub?.Bots.Bot(o.Profile) is { } row) { _dismissSheet?.Invoke(); Navigator.Go(new BotChatDestination(row.Model)); }
                else await NoticeAsync(QuickTileRules.MissingBot(tile));
                break;
            case QuickTileRoute.NewTask:
                _dismissSheet?.Invoke();
                Navigator.Open("tasks");
                break;
            case QuickTileRoute.Page p:
                if (Places.All.Any(x => x.Id == p.Id && x.Page != typeof(PlaceholderPage))) { _dismissSheet?.Invoke(); Navigator.Open(p.Id); }
                else await NoticeAsync(QuickTileRules.MissingPage(tile));
                break;
            case QuickTileRoute.Search:
                _dismissSheet?.Invoke();
                OpenQuicklyPanel.Show(XamlRoot, hub, new OpenQuicklyPanel.ShellActions(() => _ = NewChatAsync(hub), () => Navigator.Open("profiles", "new")));
                break;
            default:
                _notice.Show(QuickTileRules.NewerApp, 4);
                break;
        }
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

    /// A background tile's answer (QuickActionsViewController.say): ✓ and what it did, or the reason for 4 s.
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
        var choice = await QuickActionDialogs.ChooseAsync(XamlRoot, QuickActionChoice.Pages(PageChoices()));
        if (choice == null) return;
        var tile = await QuickActionDialogs.SetUpAsync(XamlRoot, choice.NewTile(), isNew: true, Bots(), Jobs());
        if (tile == null) return;
        Change(l => l.Add(tile));
        _notice.Show($"Added {tile.Name}", 2);
    }

    private async Task ShowSetupAsync(QuickTile tile, bool isNew)
    {
        var saved = await QuickActionDialogs.SetUpAsync(XamlRoot, tile, isNew, Bots(), Jobs());
        if (saved != null) Change(l => l.Replace(saved));
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

    /// Segoe Fluent Icons standing in for the Mac's SF Symbols.
    internal static string Glyph(string symbol) => symbol switch
    {
        "square.and.pencil" => "\uE70F",
        "mic.fill" => "\uE720",
        "waveform" => "\uE8D6",
        "paperplane.fill" => "\uE724",
        "bubble.left.fill" or "bubble.left.and.bubble.right.fill" => "\uE8BD",
        "checklist" => "\uE9D5",
        "bolt.fill" => "\uE945",
        "magnifyingglass" => "\uE721",
        "star.fill" => "\uE735",
        "heart.fill" => "\uEB51",
        "questionmark.square.dashed" => "\uE9CE",
        _ => "\uF0E2",
    };
}
