using DensitySizes = Hermes.Core.Settings.DensitySizes;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace HermesHQ.Features.Capabilities;

/// One page of Capabilities (a list, a connector, its logs…). Pages push onto a `StackHost` as the Mac's navigation
/// controller pushes them: the bar shows the page's title, Back with the page under it, its search and its ⋯ menu.
internal abstract class Screen
{
    public StackHost Host { get; set; } = null!;
    public abstract string Title { get; }
    /// The bar's search field's prompt; null: no search on this page.
    public virtual string? SearchPrompt => null;
    public string Query { get; set; } = "";
    /// The ⋯ menu, read when it opens.
    public virtual IEnumerable<MenuFlyoutItemBase> Menu() => [];
    /// Fills the page (called again on every change).
    public abstract void Build(StackPanel page);
    /// Optional max width for the scrolling column; null uses full available desktop width (e.g. Marketplace).
    public virtual double? MaxContentWidth => 1120;
    /// A bar pinned under the page (the tool editor's Save / Discard), or null.
    public virtual UIElement? Bottom => null;
    public virtual void Shown() { }
    public virtual void Hidden() { }
    /// Back was asked for: false keeps the page (an unsaved edit's "Discard Changes?").
    public virtual Task<bool> LeaveAsync() => Task.FromResult(true);
    public virtual Task RefreshAsync() => Task.CompletedTask;
    public XamlRoot? Root => Host.XamlRoot;
    public void Render() => Host.Render(this);
    public void Push(Screen s) => Host.Push(s);
    public void Pop() => Host.Pop();
}

/// The bar and the scrolling column a Screen draws into; the pages under the top one are kept as they were.
internal sealed class StackHost : UserControl
{
    private readonly List<Screen> _stack = [];
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    private readonly Button _back = new() { Visibility = Visibility.Collapsed, Padding = new Thickness(6, 4, 10, 4) };
    private readonly TextBlock _backWords = new() { FontSize = 14 };
    private readonly TextBlock _title = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBox _search = new() { Width = 240, Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _more = new() { Content = Kit.Glyph(Kit.More, 14), Padding = new Thickness(8, 6, 8, 6) };
    private readonly ScrollViewer _scroll = new()
    {
        HorizontalScrollMode = ScrollMode.Disabled,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };
    private readonly StackPanel _column = new() { Padding = new Thickness(24, 16, 24, 32), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ContentControl _bottom = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private bool _rendering;

    public Screen? Top => _stack.Count > 0 ? _stack[^1] : null;
    public IReadOnlyList<Screen> Pages => _stack;

    public StackHost()
    {
        var backFace = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        backFace.Children.Add(Kit.Glyph(Kit.Back, 12));
        backFace.Children.Add(_backWords);
        _back.Content = backFace;
        _back.Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _back.BorderThickness = new Thickness(0);
        AutomationProperties.SetName(_back, "Back");
        _back.Click += async (_, _) => await BackAsync();
        AutomationProperties.SetName(_more, "More");
        ToolTipService.SetToolTip(_more, "More");
        _more.Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _more.BorderThickness = new Thickness(0);
        _more.Click += (_, _) => ShowMenu();
        _search.TextChanged += (_, _) =>
        {
            if (Top is not { } top || top.Query == _search.Text) return;
            top.Query = _search.Text;
            Render(top);
        };

        // [WIN-50] The Mac's page bar (MacWindow.pageBar, Shell/PageBar.cs): the page-title token and the page's side.
        HermesHQ.Shell.PageBar.Title(_title, null);
        var bar = new Grid { Padding = HermesHQ.Shell.PageBar.Padding(10, 10), ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(_back);
        Grid.SetColumn(_title, 1);
        bar.Children.Add(_title);
        Grid.SetColumn(_search, 2);
        bar.Children.Add(_search);
        Grid.SetColumn(_more, 3);
        bar.Children.Add(_more);

        _scroll.Content = _column;
        _scroll.SizeChanged += (_, _) =>
        {
            if (_scroll.ViewportWidth > 0)
                _column.Width = _scroll.ViewportWidth;
        };
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(bar);
        Grid.SetRow(_scroll, 1);
        root.Children.Add(_scroll);
        Grid.SetRow(_bottom, 2);
        root.Children.Add(_bottom);
        Content = root;

        // Ctrl+F searches, F5 and Ctrl+R refresh, Alt+Left goes back (the Mac's ⌘F, ⌘R and ⌘[).
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        KeyboardAccelerators.Add(Accel(VirtualKey.F, VirtualKeyModifiers.Control, () => { if (_search.Visibility == Visibility.Visible) _search.Focus(FocusState.Keyboard); }));
        KeyboardAccelerators.Add(Accel(VirtualKey.R, VirtualKeyModifiers.Control, () => _ = Top?.RefreshAsync()));
        KeyboardAccelerators.Add(Accel(VirtualKey.Left, VirtualKeyModifiers.Menu, () => _ = BackAsync()));
        // [density] Theme › Density: the page on top draws its rows again (Compact's one-line descriptions).
        Loaded += (_, _) => { DensitySizes.Changed -= OnDensity; DensitySizes.Changed += OnDensity; };
        Unloaded += (_, _) => { DensitySizes.Changed -= OnDensity; Top?.Hidden(); };
    }

    private void OnDensity()
    {
        if (Top is { } top) Render(top);
    }

    private static KeyboardAccelerator Accel(VirtualKey key, VirtualKeyModifiers mods, Action run)
    {
        var a = new KeyboardAccelerator { Key = key, Modifiers = mods };
        a.Invoked += (_, e) => { e.Handled = true; run(); };
        return a;
    }

    public void Push(Screen screen)
    {
        Top?.Hidden();
        screen.Host = this;
        _stack.Add(screen);
        Show(screen, top: true);
        screen.Shown();
    }

    /// Replaces the stack (a place opened again from the sidebar).
    public void Reset(Screen root)
    {
        foreach (var s in _stack) s.Hidden();
        _stack.Clear();
        Push(root);
    }

    public void Pop()
    {
        if (_stack.Count < 2) return;
        var gone = _stack[^1];
        gone.Hidden();
        _stack.RemoveAt(_stack.Count - 1);
        Show(_stack[^1], top: false);
        _stack[^1].Shown();
    }

    /// Back to the page of a kind (a removed connector goes back to its list).
    public void PopTo(Func<Screen, bool> match)
    {
        while (_stack.Count > 1 && !match(_stack[^1])) Pop();
    }

    public async Task BackAsync()
    {
        if (Top is not { } top || _stack.Count < 2) return;
        if (await top.LeaveAsync() && Top == top) Pop();
    }

    private void Show(Screen s, bool top)
    {
        _search.Text = s.Query;
        _search.PlaceholderText = s.SearchPrompt ?? "";
        _search.Visibility = s.SearchPrompt != null ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(_search, s.SearchPrompt ?? "Search");
        if (top) _scroll.ChangeView(null, 0, null, true);
        Render(s);
    }

    /// Draws `s` again if it is the page on top (any thread).
    public void Render(Screen s)
    {
        if (!_ui.HasThreadAccess) { _ui.TryEnqueue(() => Render(s)); return; }
        if (Top != s || _rendering) return;
        _rendering = true;
        try
        {
            _title.Text = s.Title;
            if (_search.Text != s.Query) _search.Text = s.Query;
            _back.Visibility = _stack.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
            _backWords.Text = _stack.Count > 1 ? _stack[^2].Title : "";
            _more.Visibility = s.Menu().Any() ? Visibility.Visible : Visibility.Collapsed;
            var offset = _scroll.VerticalOffset;
            if (_scroll.ViewportWidth > 0) _column.Width = _scroll.ViewportWidth;
            _column.HorizontalAlignment = HorizontalAlignment.Stretch;
            _column.Children.Clear();
            s.Build(_column);
            _bottom.Content = s.Bottom;
            _scroll.UpdateLayout();
            _scroll.ChangeView(null, offset, null, true);
        }
        finally { _rendering = false; }
    }

    private void ShowMenu()
    {
        if (Top is not { } top) return;
        var flyout = new MenuFlyout();
        foreach (var item in top.Menu()) flyout.Items.Add(item);
        if (flyout.Items.Count > 0) flyout.ShowAt(_more);
    }
}
