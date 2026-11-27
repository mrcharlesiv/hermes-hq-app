using Hermes.Core;
using Hermes.Core.Gateways;
using Hermes.Core.Offline;
using Hermes.Core.Rpc;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using static HermesHQ.Features.Onboarding.GuideKit;

namespace HermesHQ.Features.Gateways;

/// The sidebar's foot (App/Mac/MacSidebar.swift `showGateway`): a dot for the connection (green connected, orange while
/// it connects, red offline or signed out) and the gateway's name. With more than one gateway the line is the switcher:
/// up-down chevrons after the name, a news dot when another gateway has news, and a click opens the Gateways menu —
/// the gateways ("In Use", "Signed Out", "Can’t Reach", "N New"), then Add Gateway… and Manage Gateways…
/// (App/Gateways/GatewayTitleSwitcher.swift).
public sealed class GatewayFoot : UserControl
{
    private readonly HermesClient _client;
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly Ellipse _dot = new() { Width = 7, Height = 7 };
    /// [WIN-FOOTER-GATEWAY-CLIP] One line cut in the middle to the room the gear leaves (GatewayFootFit), as the Mac's
    /// `.byTruncatingMiddle` bounded by `settingsButton.leadingAnchor - 6`; no fixed cap. Its tail ellipsis is a backstop.
    private readonly TextBlock _name = new()
    {
        TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, MaxLines = 1,
        VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(GatewayFootFit.DotGap, 0, 0, 0),
    };
    /// The name's words measured whole, in the tree (so Windows' text size applies) and never drawn.
    private readonly TextBlock _measure = new() { TextWrapping = TextWrapping.NoWrap, Opacity = 0, IsHitTestVisible = false };
    private string _whole = "";
    private readonly FontIcon _arrows = new() { Glyph = "\uE70D", FontSize = 9, Margin = new Thickness(GatewayFootFit.LineGap, 0, 0, 0) };
    private readonly Ellipse _news = new() { Width = 6, Height = 6, Margin = new Thickness(GatewayFootFit.LineGap, 0, 0, 0) };
    private readonly Button _button;
    private readonly MenuFlyout _menu = new() { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.TopEdgeAlignedLeft };
    private DateTimeOffset? _reconnectingSince;

    public GatewayFoot(HermesClient client)
    {
        _client = client;
        _name.Style = Style("CaptionTextBlockStyle");
        _name.FontSize = _measure.FontSize = Hermes.Core.Settings.ChatVisualTokens.SidebarSmall;
        _name.Foreground = Brush("HQLabel2Brush");
        _arrows.Foreground = Brush("HQLabel2Brush");
        _news.Fill = Brush("AccentFillColorDefaultBrush");
        _measure.Style = _name.Style;
        _measure.Foreground = _name.Foreground;
        AutomationProperties.SetAccessibilityView(_measure, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        AutomationProperties.SetAutomationId(_name, NameId);
        // The dot 6 before the name, the chevrons and the news dot 4 after it (MacSidebar: `-6`, `gatewayLine.spacing = 4`).
        var line = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        line.Children.Add(_dot);
        line.Children.Add(_name);
        line.Children.Add(_arrows);
        line.Children.Add(_news);
        // A canvas takes no room and measures its child at any width: the measuring words sit there, in the tree.
        var gauge = new Canvas { Width = 0, Height = 0, IsHitTestVisible = false };
        AutomationProperties.SetAccessibilityView(gauge, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        gauge.Children.Add(_measure);
        line.Children.Add(gauge);
        _button = new Button
        {
            Content = line, Style = Style("QuietButtonStyle"), Flyout = _menu, Padding = new Thickness(8, 6, 8, 6),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        _menu.Opening += (_, _) => { AppState.Gateways.CheckSoon(); BuildMenu(); };
        Content = _button;
        Loaded += (_, _) =>
        {
            AppState.Gateways.Changed += OnChanged;
            _client.Rpc.StateChanged += OnState;
            Render();
        };
        Unloaded += (_, _) =>
        {
            AppState.Gateways.Changed -= OnChanged;
            _client.Rpc.StateChanged -= OnState;
        };
    }

    /// The name's automation id (the Mac's `mac-sidebar.gateway`); the text-scale walk finds it by this.
    public const string NameId = "shell.gateway";

    /// The gateway's whole name (the foot may show it cut in the middle).
    public string WholeName => _whole;

    /// [WIN-FOOTER-GATEWAY-CLIP] Each measure cuts the name to the room left once the button's padding, the dot and its
    /// gap, the chevrons and the news dot are out (GatewayFootFit.NameRoom), from the whole name each time, so a wider
    /// sidebar or smaller text gets it back. The gear's 6 is the foot's padding and column gap (8 + 2) after the line.
    protected override Windows.Foundation.Size MeasureOverride(Windows.Foundation.Size available)
    {
        var pad = _button.Padding.Left + _button.Padding.Right + _button.BorderThickness.Left + _button.BorderThickness.Right;
        var line = available.Width - pad - _dot.Width - GatewayFootFit.DotGap;
        double Fixed(FrameworkElement e)
        {
            if (e.Visibility != Visibility.Visible) return 0;
            e.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
            return e.DesiredSize.Width - e.Margin.Left - e.Margin.Right;
        }
        var room = GatewayFootFit.NameRoom(line, Fixed(_arrows), Fixed(_news));
        var text = GatewayFootFit.Name(_whole, room, MeasureName);
        _measure.Text = "";
        if (_name.Text != text) _name.Text = text;
        _name.MaxWidth = double.IsPositiveInfinity(room) ? double.PositiveInfinity : Math.Max(0, room);
        return base.MeasureOverride(available);
    }

    private double MeasureName(string text)
    {
        _measure.Text = text;
        _measure.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        return _measure.DesiredSize.Width;
    }

    private void OnChanged()
    {
        if (AppShutdown.Stopping) return;
        _ui.TryEnqueue(() => { if (!AppShutdown.Stopping && IsLoaded) { Render(); if (_menu.IsOpen) BuildMenu(); } });
    }
    private void OnState(ConnectionState _)
    {
        if (AppShutdown.Stopping) return;
        _ui.TryEnqueue(() => { if (!AppShutdown.Stopping && IsLoaded) Render(); });
    }

    /// "Connected", "Connecting…", "Reconnecting…", "Offline", "Signed Out" (AccountView.status).
    public static string Status(ConnectionState state, bool everOpen) => state switch
    {
        ConnectionState.Open => "Connected",
        ConnectionState.Connecting => everOpen ? "Reconnecting…" : "Connecting…",
        ConnectionState.Offline => everOpen ? "Reconnecting…" : "Offline",
        _ => "Signed Out",
    };

    private void Render()
    {
        var gateways = AppState.Gateways;
        var rows = gateways.Rows;
        var switcher = rows.Count > 1;
        var switching = gateways.SwitchingTo is { } id ? rows.FirstOrDefault(r => r.Key == id)?.Title : null;
        var current = rows.FirstOrDefault(r => r.IsCurrent);
        var title = switching != null ? GatewaySwitchWords.Switching(switching) : current?.Title ?? _client.Session.Address.Base.Host;
        var state = _client.Rpc.State;
        if (state == ConnectionState.Open) _reconnectingSince = null;
        else if (_client.Rpc.EverOpen) _reconnectingSince ??= DateTimeOffset.UtcNow;
        if (_whole != title) { _whole = title; _name.Text = title; InvalidateMeasure(); }
        _name.Opacity = switching == null ? 1 : 0.6;
        _dot.Fill = Brush(state switch
        {
            ConnectionState.Open => "SystemFillColorSuccessBrush",
            ConnectionState.Connecting => "SystemFillColorCautionBrush",
            ConnectionState.Offline when _client.Rpc.EverOpen && DateTimeOffset.UtcNow - _reconnectingSince < HeaderLink.OfflineAfter
                => "SystemFillColorCautionBrush",
            _ => "SystemFillColorCriticalBrush",
        });
        var news = switcher && switching == null && gateways.OtherNews > 0;
        var arrowsWere = _arrows.Visibility;
        var newsWere = _news.Visibility;
        _arrows.Visibility = switcher ? Visibility.Visible : Visibility.Collapsed;
        _news.Visibility = news ? Visibility.Visible : Visibility.Collapsed;
        if (arrowsWere != _arrows.Visibility || newsWere != _news.Visibility) InvalidateMeasure();
        // Two gateways with one name: the tooltip adds the address, as the menu's rows do.
        var twin = current != null && rows.Any(r => r.Key != current.Key && r.Title == current.Title);
        var address = twin && switching == null ? $" ({current!.HostAndPort})" : "";
        var status = Status(state, _client.Rpc.EverOpen);
        ToolTipService.SetToolTip(_button, $"{status}: {title}{address}");
        AutomationProperties.SetName(_button, $"Gateway {title}, {status}" + (news ? ", news on another gateway" : ""));
        AutomationProperties.SetHelpText(_button, "Shows your gateways.");
        _button.IsEnabled = switching == null;
    }

    private void BuildMenu()
    {
        _menu.Items.Clear();
        var gateways = AppState.Gateways;
        var rows = gateways.Rows;
        if (rows.Count > 1)
        {
            foreach (var row in rows)
            {
                var item = new ToggleMenuFlyoutItem
                {
                    Text = row.Title, IsChecked = row.IsCurrent, IsEnabled = gateways.SwitchingTo == null,
                    // The row's status at the menu's right edge ("In Use", "Signed Out", "2 New").
                    KeyboardAcceleratorTextOverride = row.MenuStatus(rows),
                };
                AutomationProperties.SetName(item, row.Title + (row.MenuStatus(rows) is { Length: > 0 } s ? ", " + s : ""));
                var key = row.Key;
                item.Click += (_, _) =>
                {
                    if (row.IsCurrent) { item.IsChecked = true; return; }
                    _ = LaunchFlow.SwitchAsync(key);
                };
                _menu.Items.Add(item);
            }
            _menu.Items.Add(new MenuFlyoutSeparator());
        }
        _menu.Items.Add(AddGatewayItem());
        _menu.Items.Add(ManageGatewaysItem());
    }

    public static MenuFlyoutItem AddGatewayItem()
    {
        var add = new MenuFlyoutItem { Text = GatewaySwitchWords.AddGateway, Icon = new FontIcon { Glyph = "" } };
        add.Click += (_, _) => LaunchFlow.AddGateway();
        return add;
    }

    public static MenuFlyoutItem ManageGatewaysItem()
    {
        var manage = new MenuFlyoutItem { Text = GatewaySwitchWords.ManageGateways, Icon = new FontIcon { Glyph = "" } };
        manage.Click += (_, _) => ManageGatewaysView.Present();
        return manage;
    }
}
