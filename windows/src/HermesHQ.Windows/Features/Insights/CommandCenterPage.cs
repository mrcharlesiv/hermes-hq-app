using Hermes.Core.Insights;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using static HermesHQ.Features.Insights.Kit;

namespace HermesHQ.Features.Insights;

/// Tools › Status & Maintenance (App/Pages/More/CommandCenter/CommandCenter.swift, StatusDashboard.swift): the gateway's
/// status (version, messaging, its platforms, Restart Gateway, Recent Logs, Update Hermes), then its maintenance actions.
/// From `WideAt` wide it is the Mac's dashboard across the window (a headline with Restart beside it, four tiles, the
/// recent log lines filling the main column and keeping themselves fresh, the messaging apps, Hermes' update and the
/// maintenance actions as cards down the side); narrower, the list.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class CommandCenterPage : InsightsPage, IKeyRefreshing
{
    /// The Mac's dashboard shows from 960 pt of page (StatusDashboard.wideAt), which the Mac draws at 77 %: about 740 px.
    public const double WideAt = 740;

    private CommandCenterModel? _model;
    private CommandCenterLogsModel? _dashLogs;
    private CancellationTokenSource? _watch;
    private bool _wide;
    private bool _shown;
    private bool _dashMounted;
    private bool _queued;
    private ScrollViewer? _scroll;

    public CommandCenterPage()
    {
        AutomationProperties.SetAutomationId(this, "command-center.page");
        BarActions.Children.Add(BarButton("", "Refresh", () => { if (_model != null) _ = RefreshAllAsync(); }));
        SizeChanged += (_, e) =>
        {
            var wide = e.NewSize.Width >= WideAt;
            if (wide != _wide)
            {
                _wide = wide;
                Render();
                UpdateDashboardWatch();
            }
        };
        Loaded += (_, _) =>
        {
            var wide = ActualWidth >= WideAt;
            if (wide != _wide) { _wide = wide; Render(); }
            UpdateDashboardWatch();
        };
        // ⌘R on the Mac, as a pull.
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        KeyboardAccelerators.Add(Accel(VirtualKey.R, VirtualKeyModifiers.Control, () => { if (_model != null) _ = RefreshAllAsync(); }));
    }

    internal static KeyboardAccelerator Accel(VirtualKey key, VirtualKeyModifiers mods, Action run)
    {
        var k = new KeyboardAccelerator { Key = key, Modifiers = mods };
        k.Invoked += (_, e) => { e.Handled = true; run(); };
        return k;
    }

    /// View › Refresh (Ctrl+R, F5): as its own Ctrl+R.
    public void KeyRefresh() { if (_model != null) _ = RefreshAllAsync(); }

    private async Task RefreshAllAsync()
    {
        if (_model == null) return;
        await _model.RefreshAsync();
        if (_wide && _dashLogs != null) await _dashLogs.ReadAsync();
    }

    protected override void Shown()
    {
        if (Client is not { } client) return;
        if (_model == null || _model.Client != client)
        {
            _model?.Disappear();
            _model = new CommandCenterModel(client, Ui);
            _model.Changed += Queue;
            _dashLogs = new CommandCenterLogsModel(_model.Api);
            _dashLogs.Changed += Queue;
        }
        _shown = true;
        _dashMounted = false;
        _wide = ActualWidth >= WideAt;
        _model.Appear();
        UpdateSheet.Navigator_OpenOutput = action =>
        {
            var view = new ActionOutputView(action, ActionWords.Update, "Update Output");
            Push("Update Output", view, view.BarItems(), popped: view.Detach);
        };
        Render();
        UpdateDashboardWatch();
    }

    /// Starts an immediate log read and 15-second watch whenever the wide dashboard mounts or becomes visible,
    /// and stops watching when leaving wide mode or hiding (never reads dashboard logs while narrow).
    private void UpdateDashboardWatch()
    {
        var wantDash = _shown && _wide && _model != null && _dashLogs != null;
        if (wantDash && !_dashMounted)
        {
            _dashMounted = true;
            _watch?.Cancel();
            var watch = _watch = new CancellationTokenSource();
            var logs = _dashLogs!;
            _ = logs.ReadAsync();
            _ = WatchAsync(_model!, logs, watch.Token);
        }
        else if (!wantDash && _dashMounted)
        {
            _dashMounted = false;
            _watch?.Cancel();
            _watch = null;
        }
    }

    private async Task WatchAsync(CommandCenterModel model, CommandCenterLogsModel logs, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(15), ct); } catch (OperationCanceledException) { return; }
            if (!_wide || !model.Online || model.AnyActionBusy) continue;
            await model.LoadStatusAsync();
            await logs.ReadAsync();
        }
    }

    protected override void Hidden()
    {
        _shown = false;
        UpdateDashboardWatch();
        _model?.Disappear();
        UpdateSheet.Navigator_OpenOutput = null;
    }

    /// Changes come in bursts (a poll moves lines and phase together): one redraw per turn of the UI loop.
    private void Queue()
    {
        if (_queued) return;
        _queued = true;
        Ui.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => { _queued = false; Render(); });
    }

    // ------------------------------------------------------------------ the page

    private void Render()
    {
        if (_model is not { } m) return;
        var offset = _scroll?.VerticalOffset ?? 0;
        UIElement body = m.StatusLoad switch
        {
            CommandCenterModel.Load.Failed f when _wide && !m.ReadOnly && f.Reason != InsightsWire.OlderHermes => Dashboard(m, f.Reason),
            CommandCenterModel.Load.Ready when _wide => Dashboard(m, null),
            CommandCenterModel.Load.Loading => Kit.Loading($"Loading {CommandCenterNames.Page}…", m.RetryStatus),
            CommandCenterModel.Load.Failed f when !m.ReadOnly && f.Reason != InsightsWire.OlderHermes => List(m, f.Reason),
            CommandCenterModel.Load.Failed f => Error($"Couldn’t Load {CommandCenterNames.Page}", f.Reason, m.RetryStatus),
            _ => List(m, null),
        };
        SetBody(body);
        if (body is ScrollViewer sv)
        {
            _scroll = sv;
            sv.Loaded += (_, _) => sv.ChangeView(null, offset, null, true);
        }
        else _scroll = null;
    }

    // ------------------------------------------------------------------ the list (narrower than WideAt)

    private ScrollViewer List(CommandCenterModel m, string? failed)
    {
        var scroll = Column(out var col);
        AutomationProperties.SetAutomationId(scroll, "command-center.list");
        if (failed != null)
        {
            // The status couldn't be read: the reason and Try Again where it would be, and Maintenance under it.
            var retry = new Button { Content = InsightsWire.TryAgain };
            AutomationProperties.SetAutomationId(retry, "more.page.retry");
            retry.Click += (_, _) => m.RetryStatus();
            var box = new StackPanel { Spacing = 8, Padding = new Thickness(16, 12, 16, 12) };
            box.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 8,
                Children = { new FontIcon { Glyph = "", FontSize = 16 }, Text("Couldn’t Load Status", 15, bold: true) },
            });
            box.Children.Add(Text(failed, 13, secondary: true));
            box.Children.Add(retry);
            col.Children.Add(Section("Status", [box]));
        }
        else if (m.Status is { } status)
        {
            if (m.StatusRefreshFailed)
            {
                var again = new Button { Content = InsightsWire.TryAgain };
                again.Click += (_, _) => _ = m.LoadStatusAsync();
                var row = Row("Couldn’t refresh. Showing the last status.", trailing: again);
                AutomationProperties.SetAutomationId(row, "command-center.refresh-failed");
                col.Children.Add(Section(null, [row]));
            }
            var gateway = status.GatewayRunning is { } running
                ? StatusLine(status.GatewayWords, running ? Green : Red) : (UIElement)Text("—", 14, secondary: true);
            var version = Row("Version", status.VersionWords);
            AutomationProperties.SetAutomationId(version, "command-center.version");
            var messaging = Row("Messaging", trailing: gateway);
            AutomationProperties.SetAutomationId(messaging, "command-center.gateway");
            var sessions = Row("Active Sessions", status.SessionsWords);
            AutomationProperties.SetAutomationId(sessions, "command-center.sessions");
            col.Children.Add(Section("Status", [version, messaging, sessions]));
            if (status.Platforms.Count > 0)
                col.Children.Add(Section("Messaging Platforms", status.Platforms.Select(p => (UIElement)PlatformRow(p, chevronColumn: true)),
                    "For the whole gateway, all bots together. Each bot’s apps are set up in Messaging."));
            var gatewayRows = new List<UIElement>();
            if (!m.ReadOnly) gatewayRows.Add(RestartRow(m));
            var logs = Row("Recent Logs", open: () => OpenLogs(m));
            AutomationProperties.SetAutomationId(logs, "command-center.logs");
            gatewayRows.Add(logs);
            col.Children.Add(Section(null, gatewayRows, !m.ReadOnly && !m.Online && !m.AnyActionBusy ? InsightsWire.OfflineFooter : null));
            col.Children.Add(Section("Hermes", [UpdateRows(m)], UpdateFootnote(m)));
        }
        if (!m.ReadOnly) col.Children.Add(MaintenanceSection(m));
        return scroll;
    }

    /// A platform's row: its name, its state and (for one that isn't up) a chevron to Messaging; an error under them.
    private static FrameworkElement PlatformRow(GatewayStatusReport.Platform p, bool chevronColumn)
    {
        var fix = (p.IsDown || !p.IsUp) && CommandCenterModel.CanOpenMessaging;
        var color = p.IsUp ? Green : p.IsDown ? Red : Grey;
        var row = Row(p.Name, detail: p.Error, detailColor: p.Error != null ? new SolidColorBrush(Red) : null, trailing: StatusLine(p.Words, color),
            open: fix ? () => Navigator.Open("messaging") : null);
        // Every row keeps the chevron's column, even where it opens nothing, so the statuses line up across rows.
        if (!fix && chevronColumn && row is Grid g) g.Padding = new Thickness(16, 10, 33, 10);
        AutomationProperties.SetAutomationId(row, "command-center.platform." + p.Id);
        if (fix) AutomationProperties.SetHelpText(row, "Opens Messaging");
        return row;
    }

    private FrameworkElement RestartRow(CommandCenterModel m)
    {
        var left = new StackPanel { Spacing = 2 };
        left.Children.Add(Text("Gateway", 14));
        left.Children.Add(Text("Restarting stops replies for a moment.", 12, secondary: true));
        if (RestartProgress(m.Restart) is { } progress) { progress.Margin = new Thickness(0, 6, 0, 0); left.Children.Add(progress); }
        var g = new Grid { Padding = new Thickness(16, 10, 14, 10), ColumnSpacing = 12 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(left);
        if (!m.Restart.IsBusy)
        {
            var button = new Button { Content = "Restart Gateway…", IsEnabled = m.CanStartAction, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetAutomationId(button, "command-center.restart");
            button.Click += (_, _) => _ = AskRestartAsync(m);
            Grid.SetColumn(button, 1);
            g.Children.Add(button);
        }
        return g;
    }

    /// "Restarting…" with a ring, then "Gateway Restarted" or the failure's last line (GatewayRestartProgress).
    internal static FrameworkElement? RestartProgress(GatewayActionRun run)
    {
        if (GatewayRestartWords.Words(run.Phase) is not { } words) return null;
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        if (words.IsBusy) panel.Children.Add(new ProgressRing { IsActive = true, Width = 14, Height = 14 });
        var t = Text(words.Text, 13);
        // Green is for "Gateway Restarted" only: a restart that can't be followed isn't known to have worked.
        t.Foreground = words.IsError ? new SolidColorBrush(Red)
            : words.IsBusy || run.Phase is ActionPhase.UntrackedPhase ? Brush("TextFillColorSecondaryBrush") : new SolidColorBrush(Green);
        panel.Children.Add(t);
        AutomationProperties.SetAutomationId(panel, "gateway-restart.progress");
        AutomationProperties.SetName(panel, words.Text);
        return panel;
    }

    private async Task AskRestartAsync(CommandCenterModel m)
    {
        if (!m.CanStartAction || XamlRoot == null) return;
        var dialog = new ContentDialog
        {
            Title = GatewayRestartWords.ConfirmTitle, Content = GatewayRestartWords.ConfirmMessage,
            PrimaryButtonText = GatewayRestartWords.ConfirmAction, CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot,
        };
        if (await SafeDialog.ShowAsync(XamlRoot, dialog) == ContentDialogResult.Primary) m.StartRestart();
    }

    /// Under the update's rows: why this gateway can't apply the update itself.
    private static string? UpdateFootnote(CommandCenterModel m) =>
        m.Update is { } check && (!check.CanUpdateNow || m.ReadOnly) && check.Behind != 0 && m.UpdateRun == null ? check.Message : null;

    private FrameworkElement UpdateRows(CommandCenterModel m)
    {
        var check = m.Update;
        var canUpdate = !m.ReadOnly && check?.UpdateAvailable == true;
        var recheck = (check == null || check.CouldNotCheck) && m.UpdateChecked;
        if (m.UpdateRun is { } run) return UpdateRunRow(run);
        var words = check?.UpdateWords ?? (m.UpdateChecked ? "Couldn’t Check" : "Checking…");
        FrameworkElement row;
        if (canUpdate)
        {
            row = Row("Update Hermes", detail: words, titleColor: Brush("AccentTextFillColorPrimaryBrush"), open: () => AskUpdate(m));
            if (row is Control c) c.IsEnabled = m.CanStartAction;
        }
        else if (recheck)
        {
            // The status's own row offers Check Again (a push button at its trailing end on the Mac).
            var again = new Button { Content = "Check Again", IsEnabled = m.Online };
            AutomationProperties.SetAutomationId(again, "command-center.update.retry");
            again.Click += (_, _) => m.RetryUpdateCheck();
            row = Row("Update Hermes", detail: words, trailing: again);
        }
        else row = Row("Update Hermes", detail: words);
        AutomationProperties.SetAutomationId(row, "command-center.update");
        return row;
    }

    /// "Updating Studio…" with the step under way; a click brings the same sheet back (HermesUpdateRow).
    private FrameworkElement UpdateRunRow(HermesUpdate run)
    {
        var left = new StackPanel { Spacing = 3 };
        var title = Text(run.IsRunning ? run.RowTitle : run.Headline, 14);
        title.Foreground = Brush("AccentTextFillColorPrimaryBrush");
        left.Children.Add(title);
        if ((run.IsRunning ? run.RowStatus : run.Line) is { } status)
        {
            var s = Text(status, 12, secondary: true);
            s.MaxLines = 3;
            left.Children.Add(s);
        }
        var g = new Grid { ColumnSpacing = 12, Padding = new Thickness(16, 10, 14, 10) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(left);
        if (run.IsRunning)
        {
            var ring = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
            Grid.SetColumn(ring, 1);
            g.Children.Add(ring);
        }
        var b = PlainButton(g);
        AutomationProperties.SetAutomationId(b, "hermes-update.row");
        AutomationProperties.SetHelpText(b, "Shows the update");
        b.Click += (_, _) => UpdateSheet.Show(run, XamlRoot);
        return b;
    }

    internal static Button PlainButton(UIElement content) => new()
    {
        Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(0),
    };

    private void AskUpdate(CommandCenterModel m)
    {
        if (m.ReadOnly || !m.Online || m.Restart.IsBusy || m.Maintenance.IsBusy) return;
        AppLog.Note("command-center", "update hermes");
        UpdateSheet.Update(m.Client, XamlRoot);
    }

    private FrameworkElement MaintenanceSection(CommandCenterModel m)
    {
        var rows = new List<UIElement>();
        foreach (var action in Maintenance.Cases)
        {
            var title = Text(action.Title(), 14);
            title.Foreground = Brush("AccentTextFillColorPrimaryBrush");
            var left = new StackPanel { Spacing = 3, Children = { title, Text(action.Detail(), 12, secondary: true) } };
            var g = new Grid { ColumnSpacing = 12, Padding = new Thickness(16, 12, 14, 12) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.Children.Add(left);
            if (m.Maintenance.IsBusy && m.MaintenanceAction == action)
            {
                var ring = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
                Grid.SetColumn(ring, 1);
                g.Children.Add(ring);
            }
            var b = PlainButton(g);
            b.IsEnabled = m.CanStartMaintenance;
            AutomationProperties.SetName(b, action.Title());
            AutomationProperties.SetAutomationId(b, "command-center.maintenance." + action.Id());
            b.Click += (_, _) => RunMaintenance(m, action);
            rows.Add(b);
        }
        var outer = new StackPanel();
        outer.Children.Add(Section("Maintenance", rows, m.Online ? Maintenance.RunsHere : InsightsWire.OfflineFooter));
        if (m.MaintenanceAction is { } done && ActionWords.MaintenanceWords(m.Maintenance.Phase) is { } words)
        {
            var value = words.IsError && !words.IsBusy && m.Maintenance.Lines.Count == 0 ? "Failed" : words.Text.Length <= 24 ? words.Text : null;
            var row = Row($"{done.OutputTitle()} Output", value, open: () => OpenOutput(m));
            AutomationProperties.SetAutomationId(row, "command-center.maintenance.output");
            outer.Children.Add(Section(null, [row]));
        }
        return outer;
    }

    private void RunMaintenance(CommandCenterModel m, MaintenanceAction action)
    {
        if (!m.CanStartMaintenance) return;
        m.Run(action);
        OpenOutput(m);
    }

    // ------------------------------------------------------------------ the dashboard (StatusDashboard.swift)

    private ScrollViewer Dashboard(CommandCenterModel m, string? failed)
    {
        var col = new StackPanel { Spacing = 10, Padding = new Thickness(14, 4, 14, 20) };
        var scroll = new ScrollViewer { Content = col, HorizontalScrollMode = ScrollMode.Disabled };
        AutomationProperties.SetAutomationId(scroll, "command-center.dashboard");
        col.Children.Add(Headline(m, failed));
        if (m.Status is { } status) col.Children.Add(Tiles(m, status));
        var main = new Grid { ColumnSpacing = 12 };
        main.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        // The breakpoint and the Mac's 470 pt side column use the same Catalyst-to-DIP scale.
        main.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(470 * WideAt / 960) });
        main.Children.Add(LogsCard(m));
        var side = new StackPanel { Spacing = 10 };
        if (m.Status is { Platforms.Count: > 0 } s2) side.Children.Add(AppsCard(s2));
        if (m.Status != null) side.Children.Add(HermesCard(m));
        if (!m.ReadOnly) side.Children.Add(MaintenanceCard(m));
        Grid.SetColumn(side, 1);
        main.Children.Add(side);
        col.Children.Add(main);
        return scroll;
    }

    private FrameworkElement Headline(CommandCenterModel m, string? failed)
    {
        var summary = StatusSummary.Of(m.Status, failed, m.Online);
        var (glyph, color) = summary.Tone switch
        {
            StatusTone.Good => ("", Green),
            StatusTone.Warning => ("", Orange),
            StatusTone.Bad => ("", Red),
            StatusTone.Offline => ("", Grey),
            _ => ("", Grey),
        };
        var g = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 2, 0, 2) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(new FontIcon { Glyph = glyph, FontSize = 26, Foreground = new SolidColorBrush(color), VerticalAlignment = VerticalAlignment.Center });
        var words = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        var title = Text(summary.Words, 18, bold: true);
        title.FontWeight = FontWeights.Bold;
        AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        words.Children.Add(title);
        if (summary.Detail.Length > 0) { var d = Text(summary.Detail, 12, secondary: true); d.MaxLines = 2; words.Children.Add(d); }
        if (m.StatusRefreshFailed)
        {
            var r = Text("Couldn’t refresh. Showing the last status.", 11.5);
            r.Foreground = new SolidColorBrush(Orange);
            AutomationProperties.SetAutomationId(r, "command-center.refresh-failed");
            words.Children.Add(r);
        }
        Grid.SetColumn(words, 1);
        g.Children.Add(words);
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        if (failed != null)
        {
            var retry = new Button { Content = InsightsWire.TryAgain };
            AutomationProperties.SetAutomationId(retry, "more.page.retry");
            retry.Click += (_, _) => m.RetryStatus();
            right.Children.Add(retry);
        }
        if (!m.ReadOnly)
        {
            // A finished restart's words stand beside the button, not in its place.
            if (RestartProgress(m.Restart) is { } progress) { progress.MaxWidth = 360; right.Children.Add(progress); }
            if (!m.Restart.IsBusy)
            {
                var restart = new Button { Content = "Restart Gateway…", IsEnabled = m.CanStartAction };
                ToolTipService.SetToolTip(restart, "Restarting stops replies for a moment.");
                AutomationProperties.SetAutomationId(restart, "command-center.restart");
                restart.Click += (_, _) => _ = AskRestartAsync(m);
                right.Children.Add(restart);
            }
        }
        Grid.SetColumn(right, 2);
        g.Children.Add(right);
        return g;
    }

    /// A dashboard's card: a small grey heading (and what sits at its right), then what it holds (MacDashCard).
    internal static Border DashCard(string title, UIElement content, params UIElement[] trailing)
    {
        var head = new Grid { MinHeight = 24, ColumnSpacing = 8 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var t = Text(title.ToUpperInvariant(), 10.5, secondary: true, bold: true, wrap: false);
        t.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetHeadingLevel(t, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        head.Children.Add(t);
        var tr = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        foreach (var x in trailing) tr.Children.Add(x);
        Grid.SetColumn(tr, 1);
        head.Children.Add(tr);
        return new Border
        {
            Padding = new Thickness(14, 11, 14, 11), CornerRadius = new CornerRadius(12),
            Background = Brush("CardBackgroundFillColorDefaultBrush"), BorderBrush = Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
            Child = new StackPanel { Spacing = 8, Children = { head, content } },
        };
    }

    /// A dashboard's number: what it counts, the number large, a line under it (MacDashTile).
    internal static Border DashTile(string title, string value, Windows.UI.Color? dot = null, string? note = null, Brush? noteColor = null)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (dot is { } c) line.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 10, Height = 10, Fill = new SolidColorBrush(c), VerticalAlignment = VerticalAlignment.Center });
        line.Children.Add(Text(value, 21, bold: true, wrap: false));
        var n = Text(note ?? " ", 11, secondary: true, wrap: false);
        if (noteColor != null) n.Foreground = noteColor;
        var panel = new StackPanel { Spacing = 3, Children = { Text(title.ToUpperInvariant(), 10.5, secondary: true, bold: true, wrap: false), line, n } };
        var b = new Border
        {
            Padding = new Thickness(13, 10, 13, 10), CornerRadius = new CornerRadius(12), Child = panel,
            Background = Brush("CardBackgroundFillColorDefaultBrush"), BorderBrush = Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetName(b, $"{title}, {value}{(note != null ? ", " + note : "")}");
        return b;
    }

    /// Tiles side by side, as wide as each other.
    internal static Grid TileRow(params Border[] tiles)
    {
        var g = new Grid { ColumnSpacing = 12 };
        for (var i = 0; i < tiles.Length; i++)
        {
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(tiles[i], i);
            g.Children.Add(tiles[i]);
        }
        return g;
    }

    private static Grid Tiles(CommandCenterModel m, GatewayStatusReport status)
    {
        var up = status.Platforms.Count(p => p.IsUp);
        var down = status.Platforms.Count(p => p.IsDown);
        var check = m.Update;
        var (note, accent) = check != null
            ? (check.UpdateAvailable ? (check.UpdateWords, true) : (check.Words, false))
            : (m.UpdateChecked ? "Couldn’t check for updates" : "Checking for updates…", false);
        var gateway = DashTile("Messaging", status.GatewayWords, status.GatewayRunning is { } r ? (r ? Green : Red) : null, "The gateway’s chat-app service");
        AutomationProperties.SetAutomationId(gateway, "command-center.gateway");
        var version = DashTile("Hermes", status.Version ?? "—", note: note, noteColor: accent ? Brush("AccentTextFillColorPrimaryBrush") : null);
        AutomationProperties.SetAutomationId(version, "command-center.version");
        var sessions = DashTile("Active Sessions", status.SessionsWords, note: "Chats running right now");
        AutomationProperties.SetAutomationId(sessions, "command-center.sessions");
        var apps = DashTile("Messaging Apps", status.Platforms.Count == 0 ? "None" : $"{up} of {status.Platforms.Count}",
            note: status.Platforms.Count == 0 ? "Set up in Messaging" : down > 0 ? $"{down} with an error" : "connected",
            noteColor: down > 0 ? new SolidColorBrush(Red) : null);
        return TileRow(gateway, version, sessions, apps);
    }

    private FrameworkElement LogsCard(CommandCenterModel m)
    {
        var logs = _dashLogs!;
        var show = new DropDownButton { Content = $"Show  {logs.Level.Title()}" };
        AutomationProperties.SetName(show, "Show");
        AutomationProperties.SetAutomationId(show, "command-center.logs.level");
        var flyout = new MenuFlyout();
        foreach (var level in LogLevels.Cases)
        {
            var item = new RadioMenuFlyoutItem { Text = level.Title(), IsChecked = level == logs.Level, GroupName = "level" };
            item.Click += (_, _) => logs.SetLevel(level);
            flyout.Items.Add(item);
        }
        show.Flyout = flyout;
        var open = new Button { Content = "Open" };
        ToolTipService.SetToolTip(open, "The last 200 lines on their own page, with Share");
        AutomationProperties.SetAutomationId(open, "command-center.logs");
        open.Click += (_, _) => OpenLogs(m);
        var trailing = new List<UIElement>();
        if (logs.Busy && logs.State is not CommandCenterLogsModel.Load.Loading) trailing.Add(new ProgressRing { IsActive = true, Width = 14, Height = 14 });
        trailing.Add(show);
        trailing.Add(open);

        UIElement content;
        switch (logs.State)
        {
            case CommandCenterLogsModel.Load.Loading:
                content = LogsNote(null, "Reading the gateway’s log…"); break;
            case CommandCenterLogsModel.Load.Failed f:
                var retry = new Button { Content = InsightsWire.TryAgain, HorizontalAlignment = HorizontalAlignment.Center };
                retry.Click += (_, _) => logs.Retry();
                content = LogsNote("", f.Reason, retry); break;
            default:
                if (logs.Lines.Count == 0)
                {
                    content = LogsNote("", logs.EmptyText);
                    AutomationProperties.SetAutomationId(content, "command-center.logs.empty");
                    break;
                }
                var stack = new StackPanel { Padding = new Thickness(12) };
                if (logs.RefreshFailed)
                {
                    var r = Text(logs.RefreshFailedText, 12);
                    r.Foreground = new SolidColorBrush(Orange);
                    r.Margin = new Thickness(0, 0, 0, 6);
                    stack.Children.Add(r);
                }
                var i = 0;
                foreach (var line in logs.Lines.Take(120)) stack.Children.Add(LogLine(line, 3, i++));
                content = new Border
                {
                    CornerRadius = new CornerRadius(8), Background = Brush("SolidBackgroundFillColorBaseBrush"),
                    Child = new ScrollViewer { Content = stack, HorizontalScrollMode = ScrollMode.Disabled },
                };
                break;
        }
        var well = new Grid { Height = 430, Children = { content } };
        return DashCard("Recent Logs", well, [.. trailing]);
    }

    /// The logs well with no lines: a quiet mark and a sentence (and a button) in its middle.
    private static FrameworkElement LogsNote(string? glyph, string words, UIElement? extra = null)
    {
        var panel = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(20) };
        panel.Children.Add(glyph == null ? new ProgressRing { IsActive = true, Width = 16, Height = 16 } : new FontIcon { Glyph = glyph, FontSize = 20, Foreground = Brush("TextFillColorTertiaryBrush") });
        var t = Text(words, 12.5, secondary: true);
        t.TextAlignment = TextAlignment.Center;
        panel.Children.Add(t);
        if (extra != null) panel.Children.Add(extra);
        return new Border { CornerRadius = new CornerRadius(8), Background = Brush("SolidBackgroundFillColorBaseBrush"), Child = panel };
    }

    /// One log line: monospaced, red for errors and accessible amber/orange for warnings, Copy on right-click.
    internal static TextBlock LogLine(string line, int maxLines, int index)
    {
        var level = LogLines.Level(line);
        var light = (App.Window?.Content as FrameworkElement)?.ActualTheme == ElementTheme.Light;
        var warningColor = light ? Rgb(0xAD4D00) : Orange;
        var t = new TextBlock
        {
            Text = line.Length == 0 ? " " : line, FontFamily = (FontFamily)Application.Current.Resources["CodeFont"], FontSize = 11.5,
            TextWrapping = TextWrapping.Wrap, MaxLines = maxLines, TextTrimming = TextTrimming.CharacterEllipsis, Padding = new Thickness(0, 2, 0, 2),
            Foreground = level == LogLineLevel.Error ? new SolidColorBrush(Red) : level == LogLineLevel.Warning ? new SolidColorBrush(warningColor) : Brush("TextFillColorPrimaryBrush"),
        };
        AutomationProperties.SetAutomationId(t, "command-center.logs.line." + index);
        var menu = new MenuFlyout();
        var copy = new MenuFlyoutItem { Text = "Copy", Icon = new FontIcon { Glyph = "" } };
        copy.Click += (_, _) => Share.Copy(line);
        menu.Items.Add(copy);
        t.ContextFlyout = menu;
        return t;
    }

    private static FrameworkElement AppsCard(GatewayStatusReport status)
    {
        var rows = new StackPanel();
        var first = true;
        foreach (var p in status.Platforms)
        {
            if (!first) rows.Children.Add(new Border { Height = 1, Background = Brush("DividerStrokeColorDefaultBrush") });
            first = false;
            var row = PlatformRow(p, chevronColumn: false);
            if (row is Grid g) { g.Padding = new Thickness(0, 6, 0, 6); g.MinHeight = 32; }
            if (row is Button { Content: Grid bg }) { bg.Padding = new Thickness(0, 6, 0, 6); bg.MinHeight = 32; }
            rows.Children.Add(row);
        }
        var foot = Text("For the whole gateway, all bots together.", 11, secondary: true);
        foot.Margin = new Thickness(0, 5, 0, 0);
        rows.Children.Add(foot);
        var trailing = new List<UIElement>();
        if (CommandCenterModel.CanOpenMessaging)
        {
            var messaging = new Button { Content = "Messaging", FontSize = 12, Padding = new Thickness(8, 2, 8, 3) };
            AutomationProperties.SetAutomationId(messaging, "command-center.messaging");
            messaging.Click += (_, _) => Navigator.Open("messaging");
            trailing.Add(messaging);
        }
        return DashCard("Messaging Apps", rows, [.. trailing]);
    }

    private FrameworkElement HermesCard(CommandCenterModel m)
    {
        var check = m.Update;
        var canUpdate = !m.ReadOnly && check?.UpdateAvailable == true;
        var recheck = (check == null || check.CouldNotCheck) && m.UpdateChecked;
        var panel = new StackPanel { Spacing = 6 };
        if (m.UpdateRun is { } run)
        {
            var row = UpdateRunRow(run);
            if (row is Button { Content: Grid rg }) rg.Padding = new Thickness(0, 3, 0, 3);
            panel.Children.Add(row);
        }
        else
        {
            var g = new Grid { ColumnSpacing = 10 };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var words = new StackPanel { Spacing = 1 };
            words.Children.Add(Text(check?.UpdateWords ?? (m.UpdateChecked ? "Couldn’t Check" : "Checking…"), 13));
            words.Children.Add(Text(m.Status?.VersionWords ?? "", 11.5, secondary: true));
            AutomationProperties.SetAutomationId(words, "command-center.update");
            g.Children.Add(words);
            Button? button = null;
            if (canUpdate)
            {
                button = new Button { Content = "Update Hermes…", FontSize = 12, Padding = new Thickness(8, 2, 8, 3), IsEnabled = m.CanStartAction };
                AutomationProperties.SetAutomationId(button, "command-center.update.start");
                button.Click += (_, _) => AskUpdate(m);
            }
            else if (recheck)
            {
                button = new Button { Content = "Check Again", FontSize = 12, Padding = new Thickness(8, 2, 8, 3), IsEnabled = m.Online };
                AutomationProperties.SetAutomationId(button, "command-center.update.retry");
                button.Click += (_, _) => m.RetryUpdateCheck();
            }
            if (button != null) { button.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(button, 1); g.Children.Add(button); }
            panel.Children.Add(g);
        }
        if (check is { } c && (!c.CanUpdateNow || m.ReadOnly) && c.Behind != 0 && c.Message is { } message && m.UpdateRun == null)
            panel.Children.Add(Text(message, 11.5, secondary: true));
        return DashCard("Hermes Update", panel);
    }

    private FrameworkElement MaintenanceCard(CommandCenterModel m)
    {
        var rows = new StackPanel();
        var first = true;
        foreach (var action in Maintenance.Cases)
        {
            if (!first) rows.Children.Add(new Border { Height = 1, Background = Brush("DividerStrokeColorDefaultBrush") });
            first = false;
            var g = new Grid { ColumnSpacing = 10, Padding = new Thickness(0, 6, 0, 6) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.Children.Add(new StackPanel { Spacing = 1, Children = { Text(action.Title(), 13), Text(action.Detail(), 11.5, secondary: true) } });
            FrameworkElement right;
            if (m.Maintenance.IsBusy && m.MaintenanceAction == action) right = new ProgressRing { IsActive = true, Width = 14, Height = 14 };
            else
            {
                var run = new Button { Content = "Run", FontSize = 12, Padding = new Thickness(10, 2, 10, 3), IsEnabled = m.CanStartMaintenance };
                AutomationProperties.SetName(run, action.Title());
                AutomationProperties.SetAutomationId(run, "command-center.maintenance." + action.Id());
                run.Click += (_, _) => RunMaintenance(m, action);
                right = run;
            }
            right.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(right, 1);
            g.Children.Add(right);
            rows.Children.Add(g);
        }
        if (m.MaintenanceAction is { } done && ActionWords.MaintenanceWords(m.Maintenance.Phase) is { } words)
        {
            rows.Children.Add(new Border { Height = 1, Background = Brush("DividerStrokeColorDefaultBrush") });
            var line = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 6, 0, 6) };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.Children.Add(new FontIcon
            {
                Glyph = words.IsBusy ? "" : words.IsError ? "" : "", FontSize = 13,
                Foreground = words.IsBusy ? Brush("TextFillColorSecondaryBrush") : new SolidColorBrush(words.IsError ? Orange : Green),
            });
            var title = Text($"{done.OutputTitle()} Output", 13, wrap: false);
            title.Foreground = Brush("AccentTextFillColorPrimaryBrush");
            Grid.SetColumn(title, 1);
            line.Children.Add(title);
            var w = Text(words.Text, 11.5, secondary: true, wrap: false);
            w.HorizontalAlignment = HorizontalAlignment.Right;
            w.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(w, 3);
            line.Children.Add(w);
            var chev = new FontIcon { Glyph = "", FontSize = 11, Foreground = Brush("TextFillColorTertiaryBrush") };
            Grid.SetColumn(chev, 4);
            line.Children.Add(chev);
            var b = PlainButton(line);
            AutomationProperties.SetAutomationId(b, "command-center.maintenance.output");
            b.Click += (_, _) => OpenOutput(m);
            rows.Children.Add(b);
        }
        var foot = Text(m.Online ? Maintenance.RunsHere : InsightsWire.OfflineFooter, 11, secondary: true);
        foot.Margin = new Thickness(0, 5, 0, 0);
        rows.Children.Add(foot);
        return DashCard("Maintenance", rows);
    }

    // ------------------------------------------------------------------ pushed pages

    private void OpenLogs(CommandCenterModel m)
    {
        var logs = new CommandCenterLogsModel(m.Api);
        var view = new LogsView(logs);
        Push("Recent Logs", view, view.BarItems(), popped: view.Detach);
        _ = logs.ReadAsync();
    }

    private void OpenOutput(CommandCenterModel m)
    {
        if (m.MaintenanceAction is not { } action) return;
        var view = new ActionOutputView(m.Maintenance, ActionWords.MaintenanceWords, action.OutputTitle());
        Push(action.OutputTitle(), view, view.BarItems(), popped: view.Detach);
    }
}

/// Recent Logs on its own page (CommandCenterLogsView): newest first, six lines at rest (whole on a click), a level menu
/// and Share in the bar.
internal sealed partial class LogsView : UserControl
{
    private readonly CommandCenterLogsModel _model;
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    private readonly DropDownButton _level;

    public LogsView(CommandCenterLogsModel model)
    {
        _model = model;
        _level = new DropDownButton { Content = new FontIcon { Glyph = "", FontSize = 15 } };
        AutomationProperties.SetName(_level, "Level");
        AutomationProperties.SetAutomationId(_level, "command-center.logs.level");
        model.Changed += OnChanged;
        Render();
    }

    private void OnChanged() => _ui.TryEnqueue(Render);
    public void Detach() => _model.Changed -= OnChanged;

    public UIElement[] BarItems()
    {
        var share = BarButton("", "Share", () =>
        {
            if (_model.Lines.Count > 0) _ = Share.TextFileAsync(_model.Text, "Hermes Logs");
        });
        AutomationProperties.SetAutomationId(share, "command-center.logs.share");
        return [_level, share];
    }

    private void Render()
    {
        var flyout = new MenuFlyout();
        foreach (var level in LogLevels.Cases)
        {
            var item = new RadioMenuFlyoutItem { Text = level.Title(), IsChecked = level == _model.Level, GroupName = "level" };
            item.Click += (_, _) => _model.SetLevel(level);
            flyout.Items.Add(item);
        }
        _level.Flyout = flyout;
        ((FontIcon)_level.Content).Glyph = _model.Level == LogLevelFilter.All ? "" : "";
        AutomationProperties.SetItemStatus(_level, _model.Level.Title());
        switch (_model.State)
        {
            case CommandCenterLogsModel.Load.Loading:
                Content = Kit.Loading("Loading logs…", _model.Retry); return;
            case CommandCenterLogsModel.Load.Failed f:
                Content = Error("Couldn’t Load Logs", f.Reason, _model.Retry); return;
        }
        var stack = new StackPanel { Padding = new Thickness(16, 4, 16, 16) };
        if (_model.RefreshFailed)
        {
            var again = new Button { Content = InsightsWire.TryAgain };
            again.Click += (_, _) => _model.Retry();
            var g = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 3, 0, 3) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.Children.Add(Text(_model.RefreshFailedText, 13, secondary: true));
            Grid.SetColumn(again, 1);
            g.Children.Add(again);
            stack.Children.Add(g);
        }
        if (_model.Lines.Count == 0)
        {
            var empty = Empty("", LogLines.EmptyTitle(_model.ShownLevel), _model.EmptyText);
            AutomationProperties.SetAutomationId(empty, "command-center.logs.empty");
            stack.Children.Add(empty);
        }
        else
        {
            var i = 0;
            foreach (var line in _model.Lines)
            {
                var row = CommandCenterPage.LogLine(line, 6, i++);
                if (line.Length > 120)
                {
                    row.Tapped += (_, _) => row.MaxLines = row.MaxLines == 0 ? 6 : 0;
                    AutomationProperties.SetHelpText(row, "Shows the whole line");
                }
                stack.Children.Add(row);
            }
        }
        var scroll = new ScrollViewer { Content = stack, HorizontalScrollMode = ScrollMode.Disabled };
        AutomationProperties.SetAutomationId(scroll, "command-center.logs.list");
        Content = scroll;
    }
}

/// An action's output on its own page (ActionOutputView): a status line, then its lines; Share in the bar.
internal sealed partial class ActionOutputView : UserControl
{
    private readonly GatewayActionRun _run;
    private readonly Func<ActionPhase, ActionWords?> _words;
    private readonly string _title;
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();

    public ActionOutputView(GatewayActionRun run, Func<ActionPhase, ActionWords?> words, string title)
    {
        _run = run; _words = words; _title = title;
        run.Changed += OnChanged;
        Render();
    }

    private void OnChanged() => _ui.TryEnqueue(Render);
    public void Detach() => _run.Changed -= OnChanged;

    public UIElement[] BarItems()
    {
        var share = BarButton("", "Share", () =>
        {
            if (_run.Lines.Count > 0) _ = Share.TextFileAsync(string.Join("\n", _run.Lines), _title);
        });
        AutomationProperties.SetAutomationId(share, "action-output.share");
        return [share];
    }

    private void Render()
    {
        var scroll = Column(out var col);
        AutomationProperties.SetAutomationId(scroll, "action-output.list");
        if (_words(_run.Phase) is { } words)
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(16, 12, 16, 12) };
            if (words.IsBusy) line.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            else line.Children.Add(new FontIcon { Glyph = words.IsError ? "" : "", FontSize = 16, Foreground = new SolidColorBrush(words.IsError ? Orange : Green) });
            line.Children.Add(Text(words.Text, 14));
            AutomationProperties.SetAutomationId(line, "action-output.status");
            AutomationProperties.SetName(line, words.Text);
            col.Children.Add(Section(null, [line]));
        }
        UIElement output;
        if (_run.Lines.Count == 0)
            output = new Border { Padding = new Thickness(16, 12, 16, 12), Child = Text(_run.IsBusy ? "Waiting for output…" : "No output.", 14, secondary: true) };
        else
        {
            var t = new TextBlock
            {
                Text = string.Join("\n", _run.Lines.TakeLast(400)), FontFamily = (FontFamily)Application.Current.Resources["CodeFont"], FontSize = 12,
                TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Padding = new Thickness(16, 12, 16, 12),
            };
            AutomationProperties.SetAutomationId(t, "action-output.lines");
            output = t;
        }
        col.Children.Add(Section("Output", [output]));
        Content = scroll;
    }
}

/// Copy and Share for the Insights pages.
internal static class Share
{
    public static void Copy(string text) => SafeClipboard.TrySetText(text);

    /// Shares `text` as a text file (a long log travels better as a file than as a message body; ActionOutput.share).
    public static async Task TextFileAsync(string text, string name)
    {
        try
        {
            var folder = Path.Combine(Path.GetTempPath(), "command-center-share");
            Directory.CreateDirectory(folder);
            var path = Path.Combine(folder, name + ".txt");
            await File.WriteAllTextAsync(path, text);
            if (App.Window is not { } window) { Copy(text); return; }
            var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
            var manager = Windows.ApplicationModel.DataTransfer.DataTransferManagerInterop.GetForWindow(hwnd);
            void OnRequested(Windows.ApplicationModel.DataTransfer.DataTransferManager s, Windows.ApplicationModel.DataTransfer.DataRequestedEventArgs e)
            {
                s.DataRequested -= OnRequested;
                e.Request.Data.Properties.Title = name;
                e.Request.Data.SetStorageItems([file]);
            }
            manager.DataRequested += OnRequested;
            Windows.ApplicationModel.DataTransfer.DataTransferManagerInterop.ShowShareUIForWindow(hwnd);
        }
        catch (Exception e)
        {
            AppLog.Note("insights", $"share text file failed: {e.GetType().Name}");
            Copy(text);
        }
    }
}
