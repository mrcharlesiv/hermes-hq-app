using Hermes.Core.Settings;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Shapes;

namespace HermesHQ.Features.Settings;

/// Settings (App/Mac/MacSettingsWindow.swift's window, SettingsRootView in two columns): at the left the Search
/// Settings field, the gateway card and the categories (General, Appearance, Chat, Sounds, Hermes, About); at the right
/// the picked category's page, and the pages its rows open over it with a Back that names where it goes. Opens on the
/// category it was left on. A search result opens its page, or scrolls to its row and marks it.
/// `Navigator.Open("settings", "theme" | "row:ui-scale" | "about" …)` lands on that page or row.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class SettingsPage : Page
{
    private readonly TextBox _search = new() { PlaceholderText = "Search Settings" };
    private readonly ListView _categories = new() { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true };
    private readonly Button _card = new();
    private readonly TextBlock _title = new() { FontSize = 15, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    private readonly HyperlinkButton _back = new() { Visibility = Visibility.Collapsed, Padding = new Thickness(4, 2, 8, 2) };
    private readonly ScrollViewer _scroll = new() { HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly Border _form = new();
    private SettingsWindowColumn? _windowColumn;
    internal sealed record WindowRoute(string? Target);
    private readonly List<(string Title, Func<FrameworkElement> Make)> _stack = [];
    private SettingsCategory _category = SettingsCategory.General;
    private bool _gatewayMarked;
    private bool _inFrame, _syncingMark;
    private string _paneQuery = ""; // text represented by the form, not the last TextChanged notification
    private bool ShowingCategoryPane => !_gatewayMarked && !Searching && _paneQuery.Length == 0;

    /// The page on show (automation, tests).
    public static SettingsPage? Current { get; private set; }

    /// [WIN-06b] About's Export / Import / Reset on show, and the section holding them (its dialogs need it in the
    /// window); null while About isn't built or has no gateway to read (SettingsPanes.AboutCategory sets it).
    internal (SettingsFileActions Actions, FrameworkElement Host)? FileActions { get; set; }

    private void Build(bool ownWindow)
    {
        var root = new Grid();
        void Pick(SettingsCategory category)
        {
            // A native activation can report both a click and a selection. Navigate once, including when chosen by
            // a selection peer alone. Activating the category while in a detail still returns to its root.
            if (ownWindow && !_inFrame) return;
            if (ownWindow && ShowingCategoryPane && _category == category && _stack.Count == 1)
            {
                // The form is already right, but the other Settings host may have saved a different category.
                RememberCategory(category);
                return;
            }
            ClearForNavigation();
            ShowCategory(category);
        }
        AutomationProperties.SetAutomationId(_search, "settings.search");
        AutomationProperties.SetName(_search, "Search Settings");
        _search.TextChanged += (_, _) => { if (_inFrame && _search.Text != _paneQuery) ShowSearch(); };
        _search.KeyDown += (_, e) =>
        {
            // Return opens the first result, as System Settings' search does.
            if (e.Key == Windows.System.VirtualKey.Enter && Results().FirstOrDefault() is { } first) { e.Handled = true; Open(first.Target, fromSearch: true); }
            // Escape clears the search: one step, so it doesn't also go back a page or reach the window's own Escape.
            if (e.Key == Windows.System.VirtualKey.Escape && _search.Text.Length > 0) { _search.Text = ""; e.Handled = true; }
        };
        _card.HorizontalAlignment = HorizontalAlignment.Stretch;
        _card.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _card.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _card.BorderThickness = new Thickness(0);
        AutomationProperties.SetAutomationId(_card, "settings.gateway-card");
        _card.Click += (_, _) => OpenGateway();
        _categories.ItemClick += (_, e) =>
        {
            if (e.ClickedItem is FrameworkElement { Tag: SettingsCategory c }) Pick(c);
        };
        if (ownWindow)
        {
            _windowColumn = new SettingsWindowColumn(_search, _card, _categories, Glyph);
            _categories.SelectionChanged += (_, _) =>
            {
                if (!_inFrame || _syncingMark) return;
                if (_categories.SelectedItem is ListViewItem { Tag: SettingsCategory c }) Pick(c);
                else if (ShowingCategoryPane)
                {
                    // Ctrl+Space/Click can deselect *after* ItemClick. Restore the current route after WinUI's
                    // selection transaction, not the old row: search, gateway or another pick may have won since.
                    DispatcherQueue.TryEnqueue(RestoreWindowMark);
                }
            };
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _windowColumn.View.Margin = new Thickness(0, SettingsWindow.CaptionHeight, 0, 0);
            root.Children.Add(_windowColumn.View);
            Grid.SetColumn(_windowColumn.Divider, 1);
            root.Children.Add(_windowColumn.Divider); // stretches behind the transparent drag strip, not just the form
            // Observe the scroller, not the child's desired size: an oversized control or a reserved scrollbar
            // must not push the form farther inward. This also fires on viewport-only changes.
            _scroll.RegisterPropertyChangedCallback(ScrollViewer.ViewportWidthProperty, (_, _) => FitForm());
            FitForm();
        }
        else
        {
            // The main-frame fallback already has ThemeService.ApplyScale. Keep its existing layout and controls.
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(270) });
            var column = new Grid { Padding = new Thickness(12, 14, 8, 12), RowSpacing = 10 };
            column.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            column.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            column.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            column.Children.Add(_search);
            _card.Padding = new Thickness(10, 8, 10, 8);
            Grid.SetRow(_card, 1);
            column.Children.Add(_card);
            _categories.ItemsSource = SettingsCategories.All.Select(CategoryItem).ToList();
            Grid.SetRow(_categories, 2);
            column.Children.Add(_categories);
            root.Children.Add(column);
            _form.MaxWidth = 720;
            _form.Padding = new Thickness(24, 0, 24, 0);
        }
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        // The page.
        var pane = new Grid { RowSpacing = 0 };
        pane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        pane.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var inset = ownWindow ? SettingsColumnLayout.FormGutter : 20;
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Padding = new Thickness(inset, 14, inset, 8) };
        _back.Click += (_, _) => Back();
        AutomationProperties.SetAutomationId(_back, "settings.back");
        bar.Children.Add(_back);
        bar.Children.Add(_title);
        pane.Children.Add(bar);
        Grid.SetRow(_scroll, 1);
        pane.Children.Add(_scroll);
        _scroll.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        _scroll.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _scroll.Content = _form;
        if (ownWindow) pane.Margin = new Thickness(0, SettingsWindow.CaptionHeight, 0, 0);
        Grid.SetColumn(pane, root.ColumnDefinitions.Count - 1);
        root.Children.Add(pane);
        Content = root;
        Background = Kit.B("HQGroupedBrush");
        Loaded += (_, _) =>
        {
            ThemeService.Changed -= OnThemeChanged;
            ThemeService.Changed += OnThemeChanged;
            if (_windowColumn == null && _inFrame) FocusInsideEmbedded();
        };
        Unloaded += (_, _) => ThemeService.Changed -= OnThemeChanged;
    }

    private void FitForm()
    {
        var layout = new SettingsColumnLayout(ThemeService.State);
        _title.FontSize = layout.Body;
        var side = layout.FormSide(_scroll.ViewportWidth);
        if (_form.Padding.Left != side) _form.Padding = new Thickness(side, 0, side, 0);
    }

    private void OnThemeChanged()
    {
        // Cards and rows read the look's corners and words: draw the page on show again (its brushes follow by themselves).
        if (_windowColumn != null)
        {
            Background = Kit.B("HQGroupedBrush"); // changing to/from system contrast switches brush objects
            _windowColumn.ApplyTheme();
            FitForm();
        }
        RefreshGateway();
        Rebuild(keepScroll: true);
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _inFrame = true; // an embedded page and the standalone page can both be on show
        Current = this;
        if (Content == null) Build(e.Parameter is WindowRoute);
        SettingsFeature.RefreshVersion(() => DispatcherQueue.TryEnqueue(RefreshGateway));
        var arg = e.Parameter is WindowRoute window ? window.Target : (e.Parameter as PlaceArgs)?.Argument as string;
        ShowCategory(SettingsWindowPlan.OpeningCategory(FilePreferences.Shared.Get(SettingsCategories.LastCategoryKey)));
        if (arg != null) Open(arg);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e) => Leaving();

    /// The page leaves (its frame moved on, or the Settings window closed).
    internal void Leaving()
    {
        _inFrame = false; // Closed can precede Unloaded and already-posted input notifications
        ThemeService.Changed -= OnThemeChanged;
        _windowColumn?.DetachDisplay();
        if (Current == this) Current = null;
    }

    // ---------------------------------------------------------------- the Settings window (SettingsWindow)

    /// Words in Search Settings.
    internal bool Searching => _search.Text.Length > 0;

    /// A page over the category's own (Escape's step back).
    internal bool CanGoBack => _stack.Count > 1;

    internal void ClearSearch() => _search.Text = "";

    // The caller supplies the next form. Its programmatic clear can notify inline or after the new form is on
    // screen. Compare the live field with the rendered query; never discard "the next event" (it can be typing).
    private void ClearForNavigation()
    {
        _paneQuery = "";
        _search.Text = "";
    }

    // Paint/announce the route without treating our own selection write as a request to navigate to its root.
    private void SyncCategoryMark(bool keepFocus = false)
    {
        var index = SettingsColumnLayout.SelectedIndex(_category, _gatewayMarked, _windowColumn != null && Searching);
        if (_categories.SelectedIndex == index) return;
        // WinUI may refocus the selected container. Only a passive refresh restores a newer ring;
        // an explicit navigation keeps the selector's usual focus behaviour.
        var focused = keepFocus && index >= 0
            ? _categories.Items.OfType<ListViewItem>().FirstOrDefault(i => i.FocusState != FocusState.Unfocused) : null;
        var state = focused?.FocusState ?? FocusState.Unfocused;
        _syncingMark = true;
        try { _categories.SelectedIndex = index; }
        finally { _syncingMark = false; }
        if (focused != null && focused.FocusState == FocusState.Unfocused &&
            _categories.SelectedItem is ListViewItem { FocusState: not FocusState.Unfocused }) focused.Focus(state);
    }

    private void RestoreWindowMark()
    {
        if (_inFrame && IsLoaded && _categories.SelectedIndex < 0 && ShowingCategoryPane) SyncCategoryMark(keepFocus: true);
    }

    // A Windows contrast change isn't necessarily an app theme change. Keep the same form and keyboard focus.
    internal void ApplyWindowPalette()
    {
        Background = Kit.B("HQGroupedBrush");
        _windowColumn?.ApplyPalette();
    }

    /// The page's title and the category the column marks (the CI's settings-window walk).
    internal string PageTitle => _title.Text;
    internal string? MarkedCategory => _categories.SelectedIndex is var i && i >= 0 && i < SettingsCategories.All.Length ? SettingsCategories.All[i].Title() : null;

    /// MacSettingsWindow.openWindow(then:) on an open window: back to its index first, then the page asked for.
    internal void ShowAsAsked(string target, bool backToIndex)
    {
        if (backToIndex)
        {
            _search.Text = "";
            if (_gatewayMarked) OpenGateway();
            else if (_stack.Count > 1) ShowCategory(_category);
        }
        Open(target);
    }

    // ---------------------------------------------------------------- the column

    private FrameworkElement CategoryItem(SettingsCategory c)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Padding = new Thickness(2, 6, 2, 6), Tag = c };
        row.Children.Add(new FontIcon { Glyph = Glyph(c), FontSize = 15, Foreground = Kit.B("AccentTextFillColorPrimaryBrush") });
        row.Children.Add(new TextBlock { Text = c.Title(), VerticalAlignment = VerticalAlignment.Center });
        AutomationProperties.SetName(row, c.Title());
        AutomationProperties.SetAutomationId(row, "settings.category." + c.Key());
        return row;
    }

    private static string Glyph(SettingsCategory c) => c switch
    {
        SettingsCategory.General => "",
        SettingsCategory.Appearance => "",
        SettingsCategory.Chat => "",
        SettingsCategory.Sounds => "",
        SettingsCategory.Gateway => "",
        _ => "",
    };

    private void RefreshGateway()
    {
        var info = SettingsFeature.Gateway();
        var status = SettingsWords.StatusLine(info.State, info.Bots, info.Version);
        AutomationProperties.SetName(_card, SettingsWords.GatewayCardLabel(info.Name, status, info.Host));
        AutomationProperties.SetHelpText(_card, SettingsWords.GatewayCardHint);
        if (_windowColumn != null) _windowColumn.ShowGateway(info, _gatewayMarked && !Searching);
        else _card.Content = EmbeddedGatewayCard(info);
    }

    /// The original main-frame fallback card, with its visible connection status.
    private FrameworkElement EmbeddedGatewayCard(SettingsFeature.GatewayInfo info)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new FontIcon { Glyph = "", FontSize = 22, Foreground = Kit.B("AccentTextFillColorPrimaryBrush"), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) });
        var words = new StackPanel { Spacing = 1 };
        words.Children.Add(new TextBlock { Text = info.Name, FontWeight = FontWeights.SemiBold, FontSize = 15, TextWrapping = TextWrapping.Wrap });
        if (info.Host.Length > 0 && !string.Equals(info.Host, info.Name, StringComparison.OrdinalIgnoreCase))
            words.Children.Add(new TextBlock { Text = info.Host, FontSize = 12, Foreground = Kit.B("TextFillColorSecondaryBrush"), TextTrimming = TextTrimming.CharacterEllipsis });
        var state = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        state.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = Kit.B(info.State switch
        {
            GatewayConnection.Ready => "HQGreenBrush",
            GatewayConnection.Offline => "HQRedBrush",
            GatewayConnection.SignedOut => "TextFillColorTertiaryBrush",
            _ => "HQOrangeBrush",
        }), VerticalAlignment = VerticalAlignment.Center });
        state.Children.Add(new TextBlock { Text = SettingsWords.StatusLine(info.State, info.Bots, info.Version), FontSize = 12,
            Foreground = Kit.B("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap });
        words.Children.Add(state);
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        if (_gatewayMarked) grid.Background = Kit.B("HQChosenRowBrush");
        return grid;
    }

    // ---------------------------------------------------------------- the page and its stack

    public void ShowCategory(SettingsCategory c)
    {
        Mark(c);
        _stack.Add((c.Title(), () => SettingsPanes.Category(this, c)));
        Rebuild();
    }

    /// The column marks `c` (the card unmarked) and the pane is emptied for that category's pages.
    private void Mark(SettingsCategory c)
    {
        _category = c;
        _gatewayMarked = false;
        RefreshGateway();
        RememberCategory(c);
        SyncCategoryMark();
        _stack.Clear();
    }

    private static void RememberCategory(SettingsCategory category)
    {
        var value = category.Key();
        var prefs = FilePreferences.Shared;
        if (prefs.Get(SettingsCategories.LastCategoryKey) != value) prefs.Set(SettingsCategories.LastCategoryKey, value);
    }

    /// A page over the category's (its Back names the page under it).
    public void Push(string title, Func<FrameworkElement> make)
    {
        _stack.Add((title, make));
        Rebuild();
    }

    public void Back()
    {
        if (_stack.Count <= 1) return;
        _stack.RemoveAt(_stack.Count - 1);
        Rebuild();
    }

    /// The gateway card's page: the right side's own page (no Back), the card marked instead of a category.
    public void OpenGateway()
    {
        _gatewayMarked = true;
        ClearForNavigation();
        SyncCategoryMark();
        RefreshGateway();
        _stack.Clear();
        _stack.Add(("Gateway", () => SettingsPanes.GatewayPage(this)));
        Rebuild();
    }

    private void Rebuild(bool keepScroll = false)
    {
        if (_search.Text.Trim().Length > 0) { ShowSearch(); return; }
        _paneQuery = _search.Text;
        if (_windowColumn != null) SyncCategoryMark(keepFocus: true);
        var (title, make) = _stack[^1];
        _title.Text = title;
        if (_stack.Count > 1)
        {
            _back.Content = "‹ " + _stack[^2].Title;
            AutomationProperties.SetName(_back, "Back to " + _stack[^2].Title);
            _back.Visibility = Visibility.Visible;
        }
        else _back.Visibility = Visibility.Collapsed;
        // When embedded in the main window, keep focus inside Settings before replacing the form so removing a focused
        // row never drops keyboard focus back onto the sidebar's Search button (which opens its delayed ToolTip).
        if (_windowColumn == null && !keepScroll && IsLoaded) FocusInsideEmbedded();
        var offset = _scroll.VerticalOffset;
        _form.Child = make();
        if (keepScroll) _scroll.UpdateLayout();
        _scroll.ChangeView(null, keepScroll ? offset : 0, null, true);
    }

    private void FocusInsideEmbedded()
    {
        if (_back.Visibility == Visibility.Visible) _back.Focus(FocusState.Programmatic);
        else _search.Focus(FocusState.Programmatic);
    }

    // ---------------------------------------------------------------- search

    private IReadOnlyList<SettingsSearchEntry> Results() => SettingsSearch.Results(_search.Text, SettingsSearch.Index);

    private void ShowSearch()
    {
        _paneQuery = _search.Text;
        if (_windowColumn != null)
        {
            SyncCategoryMark(keepFocus: true);
            if (_gatewayMarked) RefreshGateway();
        }
        var q = _search.Text.Trim();
        if (q.Length == 0) { Rebuild(); return; }
        _back.Visibility = Visibility.Collapsed;
        _title.Text = "Search Results";
        var results = Results();
        if (results.Count == 0)
        {
            var none = new StackPanel { Spacing = 4, Margin = new Thickness(0, 60, 0, 0), HorizontalAlignment = HorizontalAlignment.Center };
            none.Children.Add(new TextBlock { Text = $"No Results for “{q}”", FontSize = 17, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
            none.Children.Add(new TextBlock { Text = "Check the spelling or try other words.", Foreground = Kit.B("TextFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Center });
            _form.Child = none;
            return;
        }
        var rows = results.Select(r => (UIElement)Kit.Nav(null, r.Label, r.Context.Length > 0 ? r.Context : null,
            () => Open(r.Target, fromSearch: true), "search." + r.Id)).ToArray();
        _form.Child = Kit.Page(Kit.Card(rows));
    }

    /// Where a search result, a deep link or another page's link goes: its category, then its page or row.
    public void Open(string target, bool fromSearch = false)
    {
        if (fromSearch) _search.Text = "";
        if (target == "gateway") { OpenGateway(); return; }
        // The category index and detail both say About. Keep the index beneath the detail for Back, as on the Mac.
        if (SettingsAboutRoute.Pages(target) is { } aboutPages) { OpenAbout(aboutPages, SettingsAboutRoute.Reveal(target)); return; }
        if (SettingsSearch.Category(target) is { } c && (c != _category || _stack.Count > 1 || _gatewayMarked)) ShowCategory(c);
        // SettingsNavigator.open `.action(id)`: About shows (the buttons are its), then the action runs as its button would.
        if (SettingsSearch.ActionId(target) != null)
        {
            if (!Searching && _paneQuery.Length > 0) Rebuild();
            RunFileAction(target);
            return;
        }
        if (target.StartsWith("row:", StringComparison.Ordinal))
        {
            // A row on the current category doesn't push a page. Restore its actual form before the first layout
            // can consume the reveal; the clear's queued TextChanged must not replace that form afterwards.
            if (!Searching && _paneQuery.Length > 0) Rebuild();
            void Land(object? s, object e)
            {
                _scroll.LayoutUpdated -= Land;
                if (Kit.Find(_scroll, target) is { } row) Kit.Flash(row);
            }
            _scroll.LayoutUpdated += Land;
            return;
        }
        if (SettingsPanes.PageFor(this, target) is { } page) Push(page.Title, page.Make);
    }

    /// About's pages for a route (`SettingsAboutRoute.Pages`), bottom first, the About category marked; `reveal` is the
    /// About row scrolled to and marked once the page is laid out (AboutView's `reveal`).
    private void OpenAbout(IReadOnlyList<string> pages, string? reveal)
    {
        const SettingsCategory category = SettingsCategory.About;
        Mark(category);
        foreach (var key in pages)
        {
            if (key == SettingsAboutRoute.CategoryKey(category))
                _stack.Add((category.Title(), () => SettingsPanes.Category(this, category)));
            else if (SettingsPanes.PageFor(this, key) is { } page)
                _stack.Add(page);
        }
        Rebuild();
        if (reveal == null) return;
        void Reveal(object? s, object e)
        {
            _scroll.LayoutUpdated -= Reveal;
            if (Kit.Find(_scroll, reveal) is { } row) Kit.Flash(row);
        }
        _scroll.LayoutUpdated += Reveal;
    }

    /// Runs a file action once About's section is in the window: after the search field's clearing has redrawn the page
    /// (its TextChanged comes later), on the actions that section shows, so its status line and dialogs are the ones on
    /// show. Without a gateway About has no such section and nothing runs, as there is no button to press.
    private void RunFileAction(string target) =>
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, async () =>
        {
            for (var i = 0; i < 40 && FileActions is not { Host.IsLoaded: true }; i++) await Task.Delay(50);
            if (FileActions is { Host.IsLoaded: true } shown) await shown.Actions.OpenAsync(target);
            else AppLog.Note("settings", "file action from search: About has no file actions on show");
        });
}
