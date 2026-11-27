using Hermes.Core;
using Hermes.Core.BotPages;
using Hermes.Core.Rpc;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;

namespace HermesHQ.Features.BotPages;

/// One screen of a More page: the list, or a page pushed from it (a profile, a platform, a webhook, a preview). The
/// Mac pushes these on More's navigation stack (`MorePageController`); here they stack inside the place's page, with
/// Back on the bar.
public abstract class Screen
{
    public PageHost Host { get; internal set; } = null!;
    public abstract string Title { get; }
    /// What goes on the bar while this screen is on top (search, +, Edit, Save…).
    public virtual IEnumerable<UIElement> Bar() => [];
    /// The body; called on every Redraw.
    public abstract UIElement Build();
    public virtual void Shown() { }
    public virtual void Left() { }
    /// Ctrl+R, as the Mac's ⌘R (a pull to refresh).
    public virtual void Refresh() { }
    /// Asked before Back (an editor with changes asks Discard Changes?).
    public virtual Task<bool> CanLeave() => Task.FromResult(true);
    /// Esc while this screen is on top; true when it handled it.
    public virtual bool Escape() => false;

    public void Redraw() { if (Host.Top == this) Host.Draw(); }
    public void RedrawBar() { if (Host.Top == this) Host.DrawBar(); }
    protected XamlRoot? Root => Host.XamlRoot;
}

/// The page a bot-pages place shows (Bot Profiles, Messaging, Webhooks, Import Sessions): the bar (Back, title, the top
/// screen's items, Refresh) over the top screen. Follows the link so a gateway coming back refreshes the page.
public abstract partial class PageHost : Page, IKeyRefreshing
{
    private readonly List<Screen> _stack = [];
    private readonly Button _back;
    private readonly TextBlock _title;
    private readonly StackPanel _bar;
    private readonly ContentControl _body;
    private readonly Grid _overlay;
    private Microsoft.UI.Dispatching.DispatcherQueue? _ui;
    private HermesClient? _client;

    public HermesClient? Client => _client;
    public IPagesGateway? Gateway { get; private set; }
    public bool Online => _client?.Rpc.State == ConnectionState.Open;
    /// The link changed (true: it is back).
    public event Action<bool>? OnlineChanged;
    public string Account => _client?.AccountId ?? "";

    protected PageHost()
    {
        _back = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, Visibility = Visibility.Collapsed,
            Style = Kit.Res<Style>("QuietButtonStyle") };
        AutomationProperties.SetName(_back, "Back");
        ToolTipService.SetToolTip(_back, "Back");
        _back.Click += async (_, _) => await Pop();
        _title = new TextBlock { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        HermesHQ.Shell.PageBar.Title(_title, null);   // [WIN-50] the Mac's page-title token (MacWindow.pageBar)
        _bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        var refresh = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, Style = Kit.Res<Style>("QuietButtonStyle") };
        AutomationProperties.SetName(refresh, "Refresh");
        ToolTipService.SetToolTip(refresh, "Refresh (Ctrl+R)");
        refresh.Click += (_, _) => Top?.Refresh();

        var bar = new Grid { Padding = HermesHQ.Shell.PageBar.Padding(10, 8), ColumnSpacing = 8 };   // [WIN-50] the page's side
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(_back);
        Grid.SetColumn(_title, 1); bar.Children.Add(_title);
        Grid.SetColumn(_bar, 2); bar.Children.Add(_bar);
        Grid.SetColumn(refresh, 3); bar.Children.Add(refresh);

        _body = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
        _overlay = new Grid();
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(bar);
        Grid.SetRow(_body, 1); root.Children.Add(_body);
        Grid.SetRowSpan(_overlay, 2); root.Children.Add(_overlay);
        Content = root;

        Key(VirtualKey.R, VirtualKeyModifiers.Control, () => Top?.Refresh());
        // Esc bubbles: a search box clearing itself handles it first.
        KeyDown += (s, e) =>
        {
            if (e.Key != VirtualKey.Escape || e.Handled) return;
            e.Handled = true;
            if (Top?.Escape() != true && _stack.Count > 1) _ = Pop();
        };
        Key(VirtualKey.Left, VirtualKeyModifiers.Menu, () => { if (_stack.Count > 1) _ = Pop(); });
    }

    private void Key(VirtualKey key, VirtualKeyModifiers mods, Action run)
    {
        var a = new KeyboardAccelerator { Key = key, Modifiers = mods };
        a.Invoked += (_, e) => { e.Handled = true; run(); };
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        KeyboardAccelerators.Add(a);
    }

    /// Where a HUD line shows.
    public Panel Overlay => _overlay;

    public Screen? Top => _stack.Count > 0 ? _stack[^1] : null;

    /// View › Refresh (Ctrl+R, F5): the page on top's own refresh, as its Ctrl+R.
    public void KeyRefresh() => Top?.Refresh();

    /// Builds the first screen for this gateway; `argument` is the PlaceArgs argument (Bot Profiles takes "new").
    protected abstract Screen First(object? argument);

    /// The same place opened again with an argument while it is on screen.
    protected virtual void Reopened(object? argument) { }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        var arg = (e.Parameter as PlaceArgs)?.Argument;
        if (_client != null && _client == AppState.Client && _stack.Count > 0) { Reopened(arg); return; }
        _client = AppState.Client;
        Gateway = _client == null ? null : new ClientPagesGateway(_client);
        if (_client != null) _client.Rpc.StateChanged += StateChanged;
        _stack.Clear();
        if (_client == null) { _body.Content = Kit.State("", "Not Signed In", ""); return; }
        Push(First(arg));
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        if (_client != null) _client.Rpc.StateChanged -= StateChanged;
        foreach (var s in _stack) s.Left();
        _stack.Clear();
        _client = null;
    }

    private void StateChanged(ConnectionState state) => _ui?.TryEnqueue(() =>
    {
        OnlineChanged?.Invoke(state == ConnectionState.Open);
        Top?.Redraw();
    });

    public void Push(Screen s)
    {
        s.Host = this;
        _stack.Add(s);
        Draw();
        s.Shown();
    }

    public async Task Pop()
    {
        if (_stack.Count <= 1 || Top is not { } top) return;
        if (!await top.CanLeave()) return;
        _stack.RemoveAt(_stack.Count - 1);
        top.Left();
        Draw();
        Top?.Shown();
    }

    /// Back to `s` (a deleted thing's page goes back to the list).
    public void PopTo(Screen s)
    {
        while (_stack.Count > 1 && Top != s)
        {
            var top = _stack[^1];
            _stack.RemoveAt(_stack.Count - 1);
            top.Left();
        }
        Draw();
    }

    internal void Draw()
    {
        if (Top is not { } top) return;
        DrawBar();
        _body.Content = top.Build();
    }

    internal void DrawBar()
    {
        if (Top is not { } top) return;
        _title.Text = top.Title;
        _back.Visibility = _stack.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        _bar.Children.Clear();
        foreach (var item in top.Bar())
        {
            if (item is FrameworkElement fe) UiTree.DetachFromParent(fe);
            _bar.Children.Add(item);
        }
    }

    /// Runs on the UI thread (answers come back on the thread pool after ConfigureAwait-free awaits in Core).
    public void Ui(Action run)
    {
        if (_ui == null || _ui.HasThreadAccess) run();
        else _ui.TryEnqueue(() => run());
    }

    public void Hud(string text) => Kit.Hud(_overlay, text);

    /// The roster, default first (the scope pill's order).
    public IReadOnlyList<Hermes.Core.Model.Bot> BotChoices => BotChoiceStore.Choices(_client?.Bots ?? []);

    public string BotName(string? profile) =>
        _client?.Bots?.FirstOrDefault(b => b.Name == (string.IsNullOrEmpty(profile) ? "default" : profile))?.DisplayName
        ?? ProfileName.Readable(profile ?? "default");

    public static BotChoiceStore Choices { get; } = new(Path.Combine(AppPaths.Root, "bot-pages.json"));
}
