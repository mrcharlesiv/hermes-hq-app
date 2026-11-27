using Hermes.Core.Gateways;
using Hermes.Core.Net;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using static HermesHQ.Features.Onboarding.GuideKit;

namespace HermesHQ.Features.Gateways;

/// Manage Gateways… (App/Settings/GatewayPageView.swift's list): every saved gateway with its name and line, the one in
/// use checked; a click switches; Rename… and Remove… on each (Remove not on the one in use); Add Gateway…; the
/// footer, which also carries a failure.
public sealed class ManageGatewaysView : UserControl
{
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly TextBlock _title, _footer;
    private readonly StackPanel _rows = new() { Spacing = 6 };
    private string? _failure;
    private string? _removing;

    public static void Present()
    {
        if (App.Window is { } w) w.PresentSheet(new ManageGatewaysView());
    }

    public ManageGatewaysView()
    {
        _title = Heading("");
        _footer = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush") };
        var add = new HyperlinkButton { Content = GatewaySwitchWords.AddGateway };
        add.Click += (_, _) => LaunchFlow.AddGateway();
        var done = new Button { Content = "Done", Style = Style("AccentButtonStyle"), HorizontalAlignment = HorizontalAlignment.Right };
        done.Click += (_, _) => App.Window?.DismissSheet();
        var column = new StackPanel { Spacing = 12, Padding = new Thickness(24) };
        foreach (var e in new UIElement[] { _title, _rows, add, _footer, done }) column.Children.Add(e);
        Content = new ScrollViewer { Content = column, HorizontalScrollMode = ScrollMode.Disabled };
        Loaded += (_, _) => { AppState.Gateways.Changed -= OnChanged; AppState.Gateways.Changed += OnChanged; AppState.Gateways.CheckSoon(); Render(); };
        Unloaded += (_, _) => AppState.Gateways.Changed -= OnChanged;
        Render();
    }

    private void OnChanged() => _ui.TryEnqueue(() => { if (!AppShutdown.Stopping) Render(); });

    private void Render()
    {
        var gateways = AppState.Gateways;
        var rows = gateways.Rows;
        // "Gateways" once there are several.
        _title.Text = rows.Count > 1 ? "Gateways" : "Gateway";
        _footer.Text = _failure ?? (rows.Count > 1
            ? $"Each gateway keeps its own chats, drafts and sign-in on this {DeviceWord.Name}. Switching doesn’t sign you out. Alerts come only from the gateway in use."
            : "Each gateway keeps its own chats, drafts and sign-in.");
        _footer.Foreground = Brush(_failure != null ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush");
        _rows.Children.Clear();
        foreach (var row in rows) _rows.Children.Add(RowView(row, rows));
    }

    private UIElement RowView(GatewayRow row, IReadOnlyList<GatewayRow> rows)
    {
        var gateways = AppState.Gateways;
        var switching = gateways.SwitchingTo == row.Key;
        var removing = gateways.IsRemoving(row.Key) || _removing == row.Key;
        var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(12, 8, 8, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (row.IsCurrent) grid.Children.Add(new FontIcon { Glyph = "", FontSize = 14, Foreground = Brush("AccentTextFillColorPrimaryBrush") });
        var words = new StackPanel { Spacing = 2 };
        words.Children.Add(new TextBlock { Text = row.Title, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        var line = switching ? "Switching…" : removing ? "Removing…"
            : row.News > 0 && GatewayNews.NewsLabel(row.News) is { } n ? string.Join(" · ", new[] { row.Subtitle, n }.Where(s => s.Length > 0))
            : row.Subtitle;
        words.Children.Add(new TextBlock { Text = line, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush") });
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        var rename = new Button { Content = "Rename…", Style = Style("QuietButtonStyle") };
        rename.Click += async (_, _) => await RenameAsync(row);
        actions.Children.Add(rename);
        if (!row.IsCurrent)
        {
            var remove = new Button { Content = "Remove…", Style = Style("QuietButtonStyle"), Foreground = Brush("SystemFillColorCriticalBrush") };
            remove.Click += async (_, _) => await RemoveAsync(row);
            actions.Children.Add(remove);
        }
        actions.IsHitTestVisible = !removing && !switching;
        Grid.SetColumn(actions, 2);
        grid.Children.Add(actions);
        var card = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(0), IsEnabled = !removing && gateways.SwitchingTo == null,
        };
        AutomationProperties.SetName(card, row.Title + ", " + (row.IsCurrent ? "In Use" : line));
        card.Click += (_, _) =>
        {
            if (row.IsCurrent) return;
            _failure = null;
            App.Window?.DismissSheet();
            _ = LaunchFlow.SwitchAsync(row.Key);
        };
        return card;
    }

    private async Task RenameAsync(GatewayRow row)
    {
        var field = new TextBox { Text = row.Label ?? "", PlaceholderText = row.Title, MaxLength = 60, IsSpellCheckEnabled = false };
        var body = new StackPanel { Spacing = 12 };
        body.Children.Add(new TextBlock { Text = $"A name for {row.HostAndPort} on this {DeviceWord.Name}. Leave it blank to use its address.", TextWrapping = TextWrapping.Wrap });
        body.Children.Add(field);
        var dialog = new ContentDialog
        {
            Title = "Rename Gateway", Content = body, PrimaryButtonText = "Save", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        if (await SafeDialog.ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary) return;
        var trimmed = field.Text.Trim();
        if (trimmed == (row.Label ?? "")) return;
        try
        {
            AppState.Gateways.Rename(row.Key, trimmed.Length == 0 ? null : trimmed);
            if (row.IsCurrent) HostWord.GatewayName = AppState.Gateways.CurrentTitle;
            _failure = null;
        }
        catch (GatewayException) { _failure = $"Couldn’t rename {row.Title}. Try again."; }
        Render();
    }

    private async Task RemoveAsync(GatewayRow row)
    {
        if (row.IsCurrent || _removing != null) return;
        var dialog = new ContentDialog
        {
            Title = $"Remove {row.Title}?", Content = SignOutWords.Remove(row.AccountName), PrimaryButtonText = "Remove Gateway",
            CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = XamlRoot,
        };
        if (await SafeDialog.ShowAsync(XamlRoot, dialog) != ContentDialogResult.Primary) return;
        _removing = row.Key;
        _failure = null;
        Render();
        try { await AppState.Gateways.RemoveAsync(row.Key, AppState.Purge); }
        catch (Exception e)
        {
            AppLog.Note("gateways", $"remove failed: {e.GetType().Name}");
            _failure = $"Couldn’t remove {row.Title}. Try again.";
        }
        _removing = null;
        Render();
    }
}
