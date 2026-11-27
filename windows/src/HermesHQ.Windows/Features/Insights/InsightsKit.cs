using Hermes.Core;
using Hermes.Core.Composer;
using Hermes.Core.Insights;
using Hermes.Core.Model;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Features.Insights;

/// A sidebar place's page as the Mac draws a More page in its content pane (App/Pages/More/Kit/MorePageKit.swift,
/// App/Mac/MacPlaceTitle.swift): the place's title at the top left of the pane's bar, the page's own buttons at its
/// trailing end, and the page under it on the grouped background. `Shown` / `Hidden` start and stop a page's polling.
public abstract class InsightsPage : Page
{
    protected readonly DispatcherQueue Ui = DispatcherQueue.GetForCurrentThread();
    protected readonly TextBlock TitleText;
    /// The bar's trailing buttons (Refresh, a filter menu, zoom).
    protected readonly StackPanel BarActions;
    /// What the page shows under its bar.
    protected readonly Border Body;
    protected PlaceArgs? Args { get; private set; }

    protected InsightsPage()
    {
        TitleText = new TextBlock { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        HermesHQ.Shell.PageBar.Title(TitleText, null);   // [WIN-50] the Mac's page-title token (MacWindow.pageBar)
        AutomationProperties.SetHeadingLevel(TitleText, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        BarActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        // [WIN-50] The Mac's page bar: the page's side, at least the bar's height (Shell/PageBar.cs).
        var bar = new Grid { Padding = HermesHQ.Shell.PageBar.Padding(10, 8), MinHeight = Hermes.Core.Shell.DesktopLook.BarHeight, ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _back = Kit.BarButton("\uE72B", "Back", () => Pop());
        _back.Visibility = Visibility.Collapsed;
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center, Children = { _back, TitleText } };
        bar.Children.Add(titleRow);
        Grid.SetColumn(BarActions, 1);
        bar.Children.Add(BarActions);
        Body = new Border();
        var root = new Grid { Background = Kit.Brush("SolidBackgroundFillColorBaseBrush") };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(bar);
        Grid.SetRow(Body, 1);
        root.Children.Add(Body);
        Content = root;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Args = e.Parameter as PlaceArgs;
        if (Args != null) { TitleText.Text = Args.Place.Title; HermesHQ.Shell.PageBar.Title(TitleText, Args.Place.Id); }
        AppState.ClientChanged += OnClientChanged;
        Shown();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        AppState.ClientChanged -= OnClientChanged;
        Hidden();
    }

    private void OnClientChanged(HermesClient? c) => Ui.TryEnqueue(() => { Hidden(); if (c != null) Shown(); });

    protected HermesClient? Client => AppState.Client;

    // ------------------------------------------------------------------ pushed pages (the Mac's navigation stack)

    private readonly Button _back;
    private readonly Stack<(string Title, UIElement? Body, UIElement[] Actions, Action? Popped)> _stack = new();

    /// Shows `content` as a page over this one (Recent Logs, an action's output): its title in the bar with a back
    /// button, its own bar buttons. `popped` runs when it is left.
    public void Push(string title, UIElement content, UIElement[]? actions = null, Action? popped = null)
    {
        _stack.Push((TitleText.Text, Body.Child, [.. BarActions.Children], popped));
        BarActions.Children.Clear();
        foreach (var a in actions ?? []) BarActions.Children.Add(a);
        TitleText.Text = title;
        Body.Child = content;
        _back.Visibility = Visibility.Visible;
    }

    /// Back to the page under the pushed one. False when nothing was pushed.
    public bool Pop()
    {
        if (_stack.Count == 0) return false;
        var (title, body, actions, popped) = _stack.Pop();
        TitleText.Text = title;
        Body.Child = body;
        BarActions.Children.Clear();
        foreach (var a in actions) BarActions.Children.Add(a);
        _back.Visibility = _stack.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        popped?.Invoke();
        return true;
    }

    /// The page's own body while nothing is pushed over it (a refresh doesn't replace a pushed page).
    protected void SetBody(UIElement content)
    {
        if (_stack.Count == 0) { Body.Child = content; return; }
        var bottom = _stack.ToArray()[^1];
        var items = _stack.ToArray();
        _stack.Clear();
        for (var i = items.Length - 1; i >= 0; i--)
            _stack.Push(i == items.Length - 1 ? (bottom.Title, content, bottom.Actions, bottom.Popped) : items[i]);
    }

    protected bool IsPushed => _stack.Count > 0;

    /// The page is on screen (or its gateway changed): read, start polling.
    protected abstract void Shown();
    /// The page left the screen: stop polling.
    protected virtual void Hidden() { }

    /// Runs `a` on the UI thread.
    protected void OnUi(Action a) { if (Ui.HasThreadAccess) a(); else Ui.TryEnqueue(() => a()); }
}

/// The pieces every Insights page draws with: page states, grouped cards and rows, the Bot picker.
public static class Kit
{
    public static Brush Brush(string key) => ThemeBrushes.Get(key);
    public static Style Style(string key) => (Style)Application.Current.Resources[key];

    /// The Mac's readable column (MacForm.readableWidth) for list pages.
    public const double ReadableWidth = 640;

    public static TextBlock Text(string text, double size = 14, bool secondary = false, bool bold = false, bool wrap = true) => new()
    {
        Text = text,
        FontSize = size,
        FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        Foreground = secondary ? Brush("TextFillColorSecondaryBrush") : Brush("TextFillColorPrimaryBrush"),
    };

    /// A scrolling column of the readable width, centred (MorePageMetrics.topGap above its first card).
    public static ScrollViewer Column(out StackPanel column, double maxWidth = ReadableWidth)
    {
        column = new StackPanel { Spacing = 0, MaxWidth = maxWidth, Padding = new Thickness(16, 4, 16, 24), HorizontalAlignment = HorizontalAlignment.Stretch };
        return new ScrollViewer { Content = column, HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    /// A grouped section: its header over a card of rows (dividers between), an optional footer under it.
    public static StackPanel Section(string? header, IEnumerable<UIElement> rows, string? footer = null)
    {
        var outer = new StackPanel { Margin = new Thickness(0, 10, 0, 10) };
        if (header != null)
        {
            var h = Text(header, 13, secondary: true, bold: true);
            h.Margin = new Thickness(16, 0, 0, 6);
            AutomationProperties.SetHeadingLevel(h, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
            outer.Children.Add(h);
        }
        outer.Children.Add(Card(rows));
        if (footer != null)
        {
            var f = Text(footer, 12, secondary: true);
            f.Margin = new Thickness(16, 6, 16, 0);
            outer.Children.Add(f);
        }
        return outer;
    }

    /// Rows in one rounded card, a hairline between them.
    public static Border Card(IEnumerable<UIElement> rows)
    {
        var stack = new StackPanel();
        var first = true;
        foreach (var r in rows)
        {
            if (!first) stack.Children.Add(new Border { Height = 1, Margin = new Thickness(16, 0, 0, 0), Background = Brush("DividerStrokeColorDefaultBrush") });
            stack.Children.Add(r);
            first = false;
        }
        return new Border
        {
            Child = stack, CornerRadius = new CornerRadius(10),
            Background = Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
        };
    }

    /// A row: its title, an optional line under it, and a value at the trailing end; a chevron when it opens something.
    public static FrameworkElement Row(string title, string? value = null, string? detail = null, Brush? detailColor = null,
        Action? open = null, UIElement? trailing = null, Brush? titleColor = null)
    {
        var left = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        var t = Text(title, 14);
        if (titleColor != null) t.Foreground = titleColor;
        left.Children.Add(t);
        if (!string.IsNullOrEmpty(detail))
        {
            var d = Text(detail, 12, secondary: true);
            if (detailColor != null) d.Foreground = detailColor;
            left.Children.Add(d);
        }
        var g = new Grid { Padding = new Thickness(16, 10, 14, 10), MinHeight = 44, ColumnSpacing = 8 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(left);
        UIElement? right = trailing;
        if (right == null && value != null)
        {
            var v = Text(value, 14, secondary: true, wrap: false);
            v.VerticalAlignment = VerticalAlignment.Center;
            right = v;
        }
        if (right != null) { Grid.SetColumn((FrameworkElement)right, 1); g.Children.Add(right); }
        if (open != null)
        {
            var chev = new FontIcon { Glyph = "", FontSize = 11, Foreground = Brush("TextFillColorTertiaryBrush"), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(chev, 2);
            g.Children.Add(chev);
            var b = new Button
            {
                Content = g, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(0),
                CornerRadius = new CornerRadius(8),
            };
            AutomationProperties.SetName(b, value != null ? $"{title}, {value}" : title);
            b.Click += (_, _) => open();
            return b;
        }
        return g;
    }

    /// A status dot and its word ("● Connected", MoreStatusLine).
    public static StackPanel StatusLine(string text, Windows.UI.Color color) => new()
    {
        Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center,
        Children =
        {
            new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 8, Height = 8, Fill = new SolidColorBrush(color), VerticalAlignment = VerticalAlignment.Center },
            Text(text, 13, secondary: true, wrap: false),
        },
    };

    public static Windows.UI.Color Rgb(uint hex) => Windows.UI.Color.FromArgb(255, (byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);
    public static readonly Windows.UI.Color Green = Rgb(0x30D158), Red = Rgb(0xFF453A), Orange = Rgb(0xFF9F0A), Grey = Rgb(0x8E8E93), Blue = Rgb(0x0A84FF);

    // ------------------------------------------------------------------ page states (MoreSkeleton, MoreErrorState, MoreEmptyState)

    /// While a first read is on its way: a ring; after 15 s the slow note with Try Again.
    public static FrameworkElement Loading(string label = "Loading…", Action? retry = null)
    {
        var ring = new ProgressRing { IsActive = true, Width = 28, Height = 28 };
        var panel = new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 440 };
        panel.Children.Add(ring);
        AutomationProperties.SetName(panel, label);
        AutomationProperties.SetAutomationId(panel, "more.page.loading");
        var timer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        timer.Interval = InsightsWire.SlowAfter;
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            var note = Text(InsightsWire.SlowPage, 13, secondary: true);
            note.TextAlignment = TextAlignment.Center;
            panel.Children.Add(note);
            if (retry != null)
            {
                var b = new Button { Content = InsightsWire.TryAgain, HorizontalAlignment = HorizontalAlignment.Center };
                b.Click += (_, _) => retry();
                panel.Children.Add(b);
            }
        };
        panel.Loaded += (_, _) => timer.Start();
        panel.Unloaded += (_, _) => timer.Stop();
        return new Grid { Children = { panel } };
    }

    /// A first read that failed with nothing to show: the reason, Try Again and Copy Details. A page this Hermes doesn't
    /// have is not a failure: "Not Available on This Hermes" with its own line, no buttons (the Mac shows the page's
    /// own glyph there when given, else the triangle).
    public static FrameworkElement Error(string title, string reason, Action retry, string? page = null, string? unavailableGlyph = null)
    {
        if (reason == InsightsWire.OlderHermes)
            return Empty(unavailableGlyph ?? "", InsightsWire.NotAvailableTitle,
                InsightsWire.NotAvailableBody(page ?? InsightsWire.PageName(title)));
        var tryAgain = new Button { Content = InsightsWire.TryAgain, Style = Style("AccentButtonStyle") };
        AutomationProperties.SetAutomationId(tryAgain, "more.page.retry");
        tryAgain.Click += (_, _) => retry();
        var copy = new Button { Content = InsightsWire.CopyDetails };
        copy.Click += async (_, _) =>
        {
            if (!SafeClipboard.TrySetText($"{title}\n{InsightsWire.Scrubbed(reason)}")) return;
            copy.Content = "Copied";
            await Task.Delay(2000);
            copy.Content = InsightsWire.CopyDetails;
        };
        var state = Empty("", title, reason, tryAgain, copy);
        AutomationProperties.SetAutomationId(state, "more.page.error");
        return state;
    }

    /// The glyph, a title, a line under it and any buttons, centred.
    public static FrameworkElement Empty(string glyph, string title, string text, params UIElement[] actions)
    {
        var panel = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 440, Padding = new Thickness(24) };
        panel.Children.Add(new FontIcon { Glyph = glyph, FontSize = 40, Foreground = Brush("TextFillColorSecondaryBrush") });
        var t = Text(title, 20, bold: true);
        t.TextAlignment = TextAlignment.Center;
        panel.Children.Add(t);
        if (text.Length > 0)
        {
            var d = Text(text, 14, secondary: true);
            d.TextAlignment = TextAlignment.Center;
            panel.Children.Add(d);
        }
        if (actions.Length > 0)
        {
            var stack = new StackPanel { Orientation = Orientation.Vertical, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) };
            foreach (var a in actions)
            {
                if (a is FrameworkElement fe) fe.HorizontalAlignment = HorizontalAlignment.Center;
                if (a is Button b && b.MinWidth == 0) b.MinWidth = 128;
                stack.Children.Add(a);
            }
            panel.Children.Add(stack);
        }
        var g = new Grid { Children = { panel } };
        AutomationProperties.SetAutomationId(g, "more.page.empty");
        return g;
    }

    /// A quiet bar button with a glyph (Refresh, a filter menu).
    public static Button BarButton(string glyph, string tip, Action click)
    {
        var b = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 15 }, Padding = new Thickness(8, 6, 8, 6),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(b, tip);
        AutomationProperties.SetName(b, tip);
        b.Click += (_, _) => click();
        return b;
    }
}

/// The bot a per-bot page reads (MoreBotPicker): a card with the label "Bot" and a pop-up of the bots at its end. Pages
/// show it only when the gateway has more than one bot. The choice is remembered per page and gateway
/// (`pages.more.bot.<page>.<account>`, MoreBotChoice); a remembered bot that left the roster reads as the first choice.
public sealed class BotPicker : UserControl
{
    private static readonly IKeyValueStore Store = new JsonFileStore(Path.Combine(AppPaths.Root, "insights.json"));
    private readonly ComboBox _box;
    private readonly HermesHQ.Controls.BotHead _head;
    private readonly string _page;
    private IReadOnlyList<Bot> _bots = [];
    public event Action<string>? Changed;
    public string Selection { get; private set; } = "default";

    public BotPicker(string page, string title = "Bot")
    {
        _page = page;
        _head = new HermesHQ.Controls.BotHead { Width = 22, Height = 22, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        _box = new ComboBox { MinWidth = 136, MinHeight = 28, Padding = new Thickness(10, 3, 10, 4), VerticalAlignment = VerticalAlignment.Center, DisplayMemberPath = "DisplayName" };
        AutomationProperties.SetName(_box, title);
        AutomationProperties.SetAutomationId(_box, "more.bot-picker");
        _box.SelectionChanged += (_, _) =>
        {
            if (_box.SelectedItem is not Bot b) return;
            UpdateHead(b);
            if (b.Name == Selection) return;
            Selection = b.Name;
            if (AppState.Client is { } c) Store.Set(Key(c.AccountId), b.Name);
            Changed?.Invoke(b.Name);
        };
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center, Children = { _head, _box } };
        var g = new Grid { Padding = new Thickness(14, 3, 6, 3), MinHeight = 35 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center, FontSize = 13.5 });
        Grid.SetColumn(right, 1);
        g.Children.Add(right);
        Content = Kit.Card([g]);
    }

    private void UpdateHead(Bot? bot)
    {
        _head.Bot = bot;
        _head.DisplayName = bot?.DisplayName ?? "";
    }

    private string Key(string account) => $"pages.more.bot.{_page}.{account}";

    /// The roster's bots, default bot first (PagesNames.scopeChoices). Returns the bot to read.
    public string SetBots(IReadOnlyList<Bot> bots, string account)
    {
        _bots = [.. bots.OrderBy(b => b.Name == "default" ? 0 : 1)];
        var saved = Store.Get(Key(account));
        Selection = saved != null && _bots.Any(b => b.Name == saved) ? saved : _bots.FirstOrDefault()?.Name ?? "default";
        var chosen = _bots.FirstOrDefault(b => b.Name == Selection);
        _box.ItemsSource = _bots;
        _box.SelectedItem = chosen;
        UpdateHead(chosen);
        Visibility = _bots.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        return Selection;
    }
}
