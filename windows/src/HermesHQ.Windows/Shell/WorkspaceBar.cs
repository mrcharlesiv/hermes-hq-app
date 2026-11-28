using Hermes.Core.Settings;
using Hermes.Core.Shell;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace HermesHQ.Shell;

/// Render model for a single open chat tab in `WorkspaceBar` (App/Mac/MacWorkspaceBar.swift `TabItem`).
public sealed record WorkspaceBarTab(
    string TabId,
    WorkspaceTabKind Kind,
    string Profile,
    string Id,
    string Title,
    bool IsActive,
    bool IsWorking,
    bool IsUnread);

/// Unified top navigation and open-chats-only workspace tab bar sitting across the outer glass shell directly above
/// the floating rounded content canvas card (App/Mac/MacWorkspaceBar.swift, `e2f3aaf39`).
/// Shows ONLY open chats (sessions and bot chats), never sidebar section tabs.
public sealed partial class WorkspaceBar : Grid
{
    private readonly Button _backButton;
    private readonly Button _forwardButton;
    private readonly Button _listToggleButton;
    private readonly ScrollViewer _scroll;
    private readonly StackPanel _strip;
    private readonly Button _addButton;

    private readonly List<TabPill> _pills = [];
    private readonly List<ProgressRing> _activeRings = [];
    private IReadOnlyList<WorkspaceBarTab> _shownTabs = [];
    private bool _listHidden;
    private bool _subscribed;

    public event Action? BackClicked;
    public event Action? ForwardClicked;
    public event Action? ToggleListClicked;
    public event Action? NewChatClicked;
    public event Action<WorkspaceBarTab>? TabSelected;
    public event Action<string>? TabCloseRequested;
    public event Action<string>? CloseOthersRequested;
    public event Action<string>? CloseToRightRequested;
    public event Action? CloseAllRequested;

    public WorkspaceBar()
    {
        Height = WindowTransparency.TopBarHeight;
        Background = new SolidColorBrush(Colors.Transparent);
        VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(this, "mac-workspace-bar");

        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // Back
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // Forward
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // List toggle
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); // Tab strip
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // + New Chat

        _backButton = MakeIconButton("\uE72B", "Back", "Back (Alt+Left)", "workspace.back", () => BackClicked?.Invoke());
        _backButton.Margin = new Thickness(0, 0, 2, 0);
        Grid.SetColumn(_backButton, 0);
        Children.Add(_backButton);

        _forwardButton = MakeIconButton("\uE72A", "Forward", "Forward (Alt+Right)", "workspace.forward", () => ForwardClicked?.Invoke());
        _forwardButton.Margin = new Thickness(0, 0, 8, 0);
        Grid.SetColumn(_forwardButton, 1);
        Children.Add(_forwardButton);

        _listToggleButton = MakeIconButton("\uE89F", "Hide List", "Hide List (Ctrl+Shift+L)", "workspace.listToggle", () => ToggleListClicked?.Invoke());
        _listToggleButton.Margin = new Thickness(0, 0, 8, 0);
        _listToggleButton.Visibility = Visibility.Collapsed;
        Grid.SetColumn(_listToggleButton, 2);
        Children.Add(_listToggleButton);

        _strip = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _scroll = new ScrollViewer
        {
            Content = _strip,
            HorizontalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
        };
        Grid.SetColumn(_scroll, 3);
        Children.Add(_scroll);

        _addButton = MakeIconButton("\uE710", "New Chat", "New Chat (Ctrl+N)", "workspace.newChat", () => NewChatClicked?.Invoke());
        Grid.SetColumn(_addButton, 4);
        Children.Add(_addButton);

        Loaded += (_, _) => Subscribe();
        Unloaded += (_, _) => Unsubscribe();
        Subscribe();
        Recolor();
    }

    private void Subscribe()
    {
        if (_subscribed) return;
        _subscribed = true;
        ThemeService.Changed += OnThemeChanged;
        WindowTransparency.Changed += OnThemeChanged;
    }

    private void Unsubscribe()
    {
        if (!_subscribed) return;
        _subscribed = false;
        ThemeService.Changed -= OnThemeChanged;
        WindowTransparency.Changed -= OnThemeChanged;
        DeactivateRings();
    }

    private void OnThemeChanged()
    {
        if (AppShutdown.Stopping) return;
        Recolor();
    }

    /// Updates navigation buttons, list toggle, and the scrollable open-chats-only tab strip.
    public void Update(
        IReadOnlyList<WorkspaceBarTab> tabs,
        bool canGoBack,
        bool canGoForward,
        bool canToggleList,
        bool isListHidden)
    {
        if (AppShutdown.Stopping) return;

        _backButton.IsEnabled = canGoBack;
        _backButton.Opacity = canGoBack ? 1.0 : 0.34;
        _forwardButton.IsEnabled = canGoForward;
        _forwardButton.Opacity = canGoForward ? 1.0 : 0.34;

        _listHidden = isListHidden;
        _listToggleButton.Visibility = canToggleList ? Visibility.Visible : Visibility.Collapsed;
        if (canToggleList)
        {
            var label = isListHidden ? "Show List" : "Hide List";
            AutomationProperties.SetName(_listToggleButton, label);
            ToolTipService.SetToolTip(_listToggleButton, $"{label} (Ctrl+Shift+L)");
        }

        if (!_shownTabs.SequenceEqual(tabs))
        {
            _shownTabs = [.. tabs];
            RebuildStrip();
        }
        Recolor();
    }

    private void DeactivateRings()
    {
        foreach (var ring in _activeRings) ring.IsActive = false;
        _activeRings.Clear();
    }

    private void RebuildStrip()
    {
        DeactivateRings();
        _strip.Children.Clear();
        _pills.Clear();

        TabPill? activePill = null;
        for (var i = 0; i < _shownTabs.Count; i++)
        {
            var tab = _shownTabs[i];
            var pill = BuildTabPill(tab, i, _shownTabs.Count);
            _pills.Add(pill);
            _strip.Children.Add(pill.Host);
            if (tab.IsActive) activePill = pill;
        }

        if (activePill != null)
        {
            var target = activePill.Host;
            DispatcherQueue?.TryEnqueue(() =>
            {
                if (!AppShutdown.Stopping && target.IsLoaded)
                    target.StartBringIntoView();
            });
        }
    }

    private TabPill BuildTabPill(WorkspaceBarTab tab, int index, int total)
    {
        var radius = ThemeService.State.ShapeRadius(ShapeRole.Control, 9);
        var host = new Border
        {
            Height = 28,
            MinWidth = 82,
            MaxWidth = 204,
            CornerRadius = new CornerRadius(radius),
            BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderBrush = new SolidColorBrush(Colors.Transparent),
        };
        ToolTipService.SetToolTip(host, tab.Title);

        var grid = new Grid();

        // Main selectable button occupying the pill
        var contentStack = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 5,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(10, 0, 24, 0),
        };

        Ellipse? dot = null;
        if (tab.IsWorking || (tab.IsUnread && !tab.IsActive))
        {
            dot = new Ellipse
            {
                Width = 5.5,
                Height = 5.5,
                VerticalAlignment = VerticalAlignment.Center,
                IsHitTestVisible = false,
            };
            AutomationProperties.SetAccessibilityView(dot, AccessibilityView.Raw);
            contentStack.Children.Add(dot);
        }

        FontIcon? icon = null;
        if (tab.IsWorking)
        {
            var ring = new ProgressRing
            {
                IsActive = true,
                Width = 12,
                Height = 12,
                MinWidth = 0,
                MinHeight = 0,
                VerticalAlignment = VerticalAlignment.Center,
                IsHitTestVisible = false,
            };
            AutomationProperties.SetAccessibilityView(ring, AccessibilityView.Raw);
            _activeRings.Add(ring);
            contentStack.Children.Add(ring);
        }
        else
        {
            icon = new FontIcon
            {
                Glyph = tab.Kind == WorkspaceTabKind.Bot ? "\uE99A" : "\uE8BD",
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
                IsHitTestVisible = false,
            };
            AutomationProperties.SetAccessibilityView(icon, AccessibilityView.Raw);
            contentStack.Children.Add(icon);
        }

        var titleBlock = new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(tab.Title) ? "Chat" : tab.Title,
            FontSize = 12.5,
            FontWeight = tab.IsActive ? FontWeights.Medium : FontWeights.Normal,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
            MaxWidth = 138,
            VerticalAlignment = VerticalAlignment.Center,
        };
        contentStack.Children.Add(titleBlock);

        var selectBtn = new Button
        {
            Content = contentStack,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            VerticalContentAlignment = VerticalAlignment.Center,
            CornerRadius = new CornerRadius(radius),
        };
        AutomationProperties.SetName(selectBtn, tab.Title);
        AutomationProperties.SetAutomationId(selectBtn, $"workspace.tab.{tab.TabId}");
        selectBtn.Click += (_, _) => TabSelected?.Invoke(tab);

        // Close button overlaid on trailing edge — visible on hover or while tab is active
        var closeIcon = new FontIcon { Glyph = "\uE711", FontSize = 9 };
        var closeBtn = new Button
        {
            Content = closeIcon,
            Width = 18,
            Height = 18,
            Padding = new Thickness(0),
            Margin = new Thickness(0, 0, 4, 0),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(4),
            Opacity = tab.IsActive ? 0.85 : 0,
        };
        AutomationProperties.SetName(closeBtn, $"Close {tab.Title}");
        AutomationProperties.SetAutomationId(closeBtn, $"workspace.tab.close.{tab.TabId}");
        ToolTipService.SetToolTip(closeBtn, $"Close {tab.Title}");
        closeBtn.Click += (_, _) => TabCloseRequested?.Invoke(tab.TabId);

        // Context menu: Close Tab, Close Other Tabs, Close Tabs to the Right, Close All Tabs
        var flyout = BuildTabContextMenu(tab.TabId, index, total);
        host.ContextFlyout = flyout;
        selectBtn.ContextFlyout = flyout;

        grid.Children.Add(selectBtn);
        grid.Children.Add(closeBtn);
        host.Child = grid;

        var pill = new TabPill(tab, host, selectBtn, closeBtn, closeIcon, titleBlock, icon, dot);
        host.PointerEntered += (_, _) => { pill.Hovered = true; ColorPill(pill); };
        host.PointerExited += (_, _) => { pill.Hovered = false; ColorPill(pill); };
        ColorPill(pill);
        return pill;
    }

    private MenuFlyout BuildTabContextMenu(string tabId, int index, int total)
    {
        var menu = new MenuFlyout();

        var closeItem = new MenuFlyoutItem { Text = "Close Tab", Icon = new FontIcon { Glyph = "\uE711" } };
        closeItem.Click += (_, _) => TabCloseRequested?.Invoke(tabId);
        menu.Items.Add(closeItem);

        var hasOthers = total > 1;
        var hasRight = index + 1 < total;
        if (hasOthers || hasRight)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            if (hasOthers)
            {
                var others = new MenuFlyoutItem { Text = "Close Other Tabs" };
                others.Click += (_, _) => CloseOthersRequested?.Invoke(tabId);
                menu.Items.Add(others);
            }
            if (hasRight)
            {
                var right = new MenuFlyoutItem { Text = "Close Tabs to the Right" };
                right.Click += (_, _) => CloseToRightRequested?.Invoke(tabId);
                menu.Items.Add(right);
            }
        }
        if (hasOthers)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            var all = new MenuFlyoutItem { Text = "Close All Tabs" };
            all.Click += (_, _) => CloseAllRequested?.Invoke();
            menu.Items.Add(all);
        }
        return menu;
    }

    private static Button MakeIconButton(string glyph, string label, string tooltip, string automationId, Action onClick)
    {
        var btn = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 13 },
            Width = 28,
            Height = 28,
            Padding = new Thickness(0),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            CornerRadius = new CornerRadius(8),
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(btn, label);
        AutomationProperties.SetAutomationId(btn, automationId);
        ToolTipService.SetToolTip(btn, tooltip);
        btn.Click += (_, _) => onClick();
        return btn;
    }

    public void Recolor()
    {
        if (AppShutdown.Stopping) return;

        var dark = ThemeService.Dark;
        var radius = ThemeService.State.ShapeRadius(ShapeRole.Control, 8);
        var tabRadius = ThemeService.State.ShapeRadius(ShapeRole.Control, 9);
        var labelBrush = ThemeBrushes.Get("HQLabelBrush");

        foreach (var btn in new[] { _backButton, _forwardButton, _listToggleButton, _addButton })
        {
            btn.CornerRadius = new CornerRadius(radius);
            btn.Foreground = labelBrush;
        }

        if (_listHidden)
        {
            _listToggleButton.Background = new SolidColorBrush(dark
                ? Color.FromArgb((byte)Math.Round(255 * 0.11), 255, 255, 255)
                : Color.FromArgb((byte)Math.Round(255 * 0.65), 255, 255, 255));
        }
        else
        {
            _listToggleButton.Background = new SolidColorBrush(Colors.Transparent);
        }

        foreach (var pill in _pills)
        {
            pill.Host.CornerRadius = new CornerRadius(tabRadius);
            pill.SelectButton.CornerRadius = new CornerRadius(tabRadius);
            ColorPill(pill);
        }
    }

    private static void ColorPill(TabPill pill)
    {
        var dark = ThemeService.Dark;
        var tokens = ThemeService.Tokens;
        var active = pill.Tab.IsActive;

        pill.Title.Foreground = new SolidColorBrush(ThemeService.ToColor(
            active ? tokens.Label : tokens.Label.Alpha(tokens.Label.A * (dark ? 0.72 : 0.65))));
        if (pill.Icon != null)
        {
            pill.Icon.Foreground = new SolidColorBrush(ThemeService.ToColor(
                active ? tokens.Label : tokens.Label.Alpha(tokens.Label.A * (dark ? 0.62 : 0.55))));
        }
        if (pill.Dot != null)
        {
            pill.Dot.Fill = ThemeBrushes.Get("HQTintBrush");
        }
        pill.CloseIcon.Foreground = ThemeBrushes.Get("HQLabel2Brush");
        pill.CloseButton.Opacity = (pill.Hovered || active) ? 0.85 : 0;

        if (active)
        {
            pill.Host.Background = new SolidColorBrush(dark
                ? Color.FromArgb((byte)Math.Round(255 * 0.12), 255, 255, 255)
                : Color.FromArgb((byte)Math.Round(255 * 0.78), 255, 255, 255));
            pill.Host.BorderBrush = new SolidColorBrush(dark
                ? Color.FromArgb((byte)Math.Round(255 * 0.11), 255, 255, 255)
                : Color.FromArgb((byte)Math.Round(255 * 0.06), 0, 0, 0));
        }
        else if (pill.Hovered)
        {
            pill.Host.Background = new SolidColorBrush(dark
                ? Color.FromArgb((byte)Math.Round(255 * 0.07), 255, 255, 255)
                : Color.FromArgb((byte)Math.Round(255 * 0.045), 0, 0, 0));
            pill.Host.BorderBrush = new SolidColorBrush(Colors.Transparent);
        }
        else
        {
            pill.Host.Background = new SolidColorBrush(Colors.Transparent);
            pill.Host.BorderBrush = new SolidColorBrush(Colors.Transparent);
        }
    }

    private sealed class TabPill(
        WorkspaceBarTab tab,
        Border host,
        Button selectButton,
        Button closeButton,
        FontIcon closeIcon,
        TextBlock title,
        FontIcon? icon,
        Ellipse? dot)
    {
        public WorkspaceBarTab Tab { get; } = tab;
        public Border Host { get; } = host;
        public Button SelectButton { get; } = selectButton;
        public Button CloseButton { get; } = closeButton;
        public FontIcon CloseIcon { get; } = closeIcon;
        public TextBlock Title { get; } = title;
        public FontIcon? Icon { get; } = icon;
        public Ellipse? Dot { get; } = dot;
        public bool Hovered { get; set; }
    }
}
