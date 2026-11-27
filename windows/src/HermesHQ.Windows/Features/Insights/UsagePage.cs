using System.Globalization;
using Hermes.Core;
using Hermes.Core.Insights;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;
using static HermesHQ.Features.Insights.Kit;

namespace HermesHQ.Features.Insights;

/// Tools › Usage (CommandCenterUsage.swift, UsageDashboard.swift): the whole gateway's history, which neither the chat's
/// Usage & Limits nor its usage report shows. Wide enough, the Mac's dashboard: "Last 30 Days" with the period switch,
/// four tiles, the daily chart across the window (read and written, or sessions; the day under the pointer named), and
/// the models and skills side by side with a bar for each share. Narrower, the list: Period, three tiles, Daily Tokens,
/// By Model, Top Skills.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class UsagePage : InsightsPage, HermesHQ.Shell.IKeyRefreshing
{
    private UsagePageModel? _model;
    private HermesClient? _client;
    private bool _wide;
    private bool _queued;
    private bool _sessions;
    private UsageReport.Day? _hovered;

    public UsagePage()
    {
        AutomationProperties.SetAutomationId(this, "more-usage.page");
        BarActions.Children.Add(BarButton("", "Refresh", () => _ = _model?.ReadAsync()));
        KeyboardAcceleratorPlacementMode = Microsoft.UI.Xaml.Input.KeyboardAcceleratorPlacementMode.Hidden;
        KeyboardAccelerators.Add(CommandCenterPage.Accel(VirtualKey.R, VirtualKeyModifiers.Control, () => _ = _model?.ReadAsync()));
        SizeChanged += (_, e) =>
        {
            var wide = e.NewSize.Width >= CommandCenterPage.WideAt;
            if (wide != _wide) { _wide = wide; Render(); }
        };
    }

    protected override void Shown()
    {
        if (Client is not { } client) return;
        if (_model == null || _client != client)
        {
            _client = client;
            _model = new UsagePageModel(new CommandCenterApi(client.Session));
            _model.Changed += Queue;
        }
        _wide = ActualWidth >= CommandCenterPage.WideAt;
        Render();
        _model.Appear();
    }

    /// View › Refresh (Ctrl+R, F5): as its own Ctrl+R and its Refresh button.
    public void KeyRefresh() => _ = _model?.ReadAsync();

    private void Queue()
    {
        if (_queued) return;
        _queued = true;
        Ui.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => { _queued = false; Render(); });
    }

    private void Render()
    {
        if (_model is not { } m) return;
        UIElement body = m.State switch
        {
            UsagePageModel.Load.Loading => Kit.Loading($"Loading {CommandCenterNames.Usage}…", m.Retry),
            UsagePageModel.Load.Failed f => Error($"Couldn’t Load {CommandCenterNames.Usage}", f.Reason, m.Retry),
            // Also with nothing used yet: the switch stays where it was and keeps its kind.
            _ when _wide && m.Usage != null => Dashboard(m, m.Usage),
            _ => List(m),
        };
        SetBody(body);
    }

    // ------------------------------------------------------------------ the list

    private ScrollViewer List(UsagePageModel m)
    {
        var scroll = Column(out var col);
        AutomationProperties.SetAutomationId(scroll, "more-usage.list");
        var period = new ComboBox { MinWidth = 120, VerticalAlignment = VerticalAlignment.Center };
        foreach (var d in UsageFormat.Periods) period.Items.Add(new ComboBoxItem { Content = $"{d} Days", Tag = d });
        period.SelectedIndex = Array.IndexOf(UsageFormat.Periods, m.Days);
        period.SelectionChanged += (_, _) => { if (period.SelectedItem is ComboBoxItem { Tag: int d }) m.SetDays(d); };
        AutomationProperties.SetName(period, "Period");
        AutomationProperties.SetAutomationId(period, "more-usage.period");
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { Text("Period", 14) } };
        if (m.Busy) label.Children.Add(new ProgressRing { IsActive = true, Width = 14, Height = 14 });
        var periodRow = new Grid { Padding = new Thickness(16, 6, 8, 6), MinHeight = 44 };
        periodRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        periodRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        label.VerticalAlignment = VerticalAlignment.Center;
        periodRow.Children.Add(label);
        Grid.SetColumn(period, 1);
        periodRow.Children.Add(period);
        col.Children.Add(Section(null, [periodRow]));
        if (m.RefreshFailed) col.Children.Add(Section(null, [RefreshFailedRow(m)]));
        if (m.Usage is not { } usage) return scroll;
        if (usage.IsEmpty)
        {
            var empty = Empty("", "No Usage Yet", "Usage shows up after your bots have worked.");
            AutomationProperties.SetAutomationId(empty, "more-usage.empty");
            empty.Margin = new Thickness(0, 24, 0, 24);
            col.Children.Add(empty);
            return scroll;
        }
        // One card, three numbers side by side.
        var tiles = new Grid { ColumnSpacing = 8, Padding = new Thickness(16, 12, 16, 12) };
        var items = new (string Title, string Value, string Key)[]
        {
            ("Tokens", UsageFormat.Compact(usage.Tokens), "tokens"),
            ("Sessions", usage.Sessions is { } s ? UsageFormat.Compact(s) : "—", "sessions"),
            ("Est. Cost", UsageFormat.Cost(usage.Cost), "cost"),
        };
        for (var i = 0; i < items.Length; i++)
        {
            tiles.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var v = Text(items[i].Value, 22, bold: true, wrap: false);
            var t = new StackPanel { Spacing = 3, Children = { v, Text(items[i].Title, 12, secondary: true) } };
            AutomationProperties.SetName(t, $"{(items[i].Title == "Est. Cost" ? "Estimated cost" : items[i].Title)}, {items[i].Value}");
            AutomationProperties.SetAutomationId(t, "more-usage.tile." + items[i].Key);
            Grid.SetColumn(t, i);
            tiles.Children.Add(t);
        }
        col.Children.Add(Section(null, [tiles]));
        if (usage.Daily.Count > 0)
        {
            var chart = new UsageChart(usage, sessions: false, split: false, dayFormat: "MMM d", desiredTicks: 4) { Height = 190, Margin = new Thickness(12, 8, 12, 8) };
            col.Children.Add(Section("Daily Tokens", [chart]));
        }
        if (usage.Models.Count > 0)
        {
            var rows = usage.Models.Take(12).Select(r =>
            {
                var row = Row(r.Id, UsageFormat.Compact(r.Tokens), detail: UsageFormat.ModelLine(r));
                AutomationProperties.SetName(row, $"{r.Id}, {UsageFormat.Compact(r.Tokens)} tokens, {UsageFormat.Sessions(r.Sessions)}");
                return (UIElement)row;
            });
            col.Children.Add(Section("By Model", rows));
        }
        if (usage.Skills.Count > 0)
            col.Children.Add(Section("Top Skills", usage.Skills.Take(12).Select(r => (UIElement)Row(r.Id, UsageFormat.Actions(r.Count)))));
        return scroll;
    }

    private static FrameworkElement RefreshFailedRow(UsagePageModel m)
    {
        var again = new Button { Content = InsightsWire.TryAgain };
        again.Click += (_, _) => m.Retry();
        var row = Row(m.RefreshFailedText, trailing: again);
        AutomationProperties.SetAutomationId(row, "more-usage.refresh-failed");
        return row;
    }

    // ------------------------------------------------------------------ the dashboard (UsageDashboard.swift)

    private FrameworkElement Dashboard(UsagePageModel m, UsageReport usage)
    {
        if (usage.IsEmpty)
        {
            // Nothing used in this period: keep the headline & period switch at top and center the empty message
            // in the remaining viewport height (matching Mac's vertical centering).
            var root = new Grid { Padding = new Thickness(14, 4, 14, 20) };
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            AutomationProperties.SetAutomationId(root, "more-usage.dashboard");
            root.Children.Add(Headline(m));
            var empty = Empty("", "No Usage Yet", "Usage shows up after your bots have worked.");
            AutomationProperties.SetAutomationId(empty, "more-usage.empty");
            Grid.SetRow(empty, 1);
            root.Children.Add(empty);
            return root;
        }
        var col = new StackPanel { Spacing = 10, Padding = new Thickness(14, 4, 14, 20) };
        var scroll = new ScrollViewer { Content = col, HorizontalScrollMode = ScrollMode.Disabled };
        AutomationProperties.SetAutomationId(scroll, "more-usage.dashboard");
        col.Children.Add(Headline(m));
        var peak = usage.Peak;
        var tokens = CommandCenterPage.DashTile("Tokens", UsageFormat.Compact(usage.Tokens), note: usage.TokensNote);
        AutomationProperties.SetAutomationId(tokens, "more-usage.tile.tokens");
        var sessions = CommandCenterPage.DashTile("Sessions", usage.Sessions is { } s ? UsageFormat.Compact(s) : "—", note: usage.SessionsNote);
        AutomationProperties.SetAutomationId(sessions, "more-usage.tile.sessions");
        var cost = CommandCenterPage.DashTile("Estimated Cost", UsageFormat.Cost(usage.Cost), note: usage.CostNote);
        AutomationProperties.SetAutomationId(cost, "more-usage.tile.cost");
        var busiest = CommandCenterPage.DashTile("Busiest Day", peak?.Date.ToString("MMM d", CultureInfo.CurrentCulture) ?? "—",
            note: peak != null ? $"{UsageFormat.Compact(peak.Tokens)} tokens · {UsageFormat.Sessions(peak.Sessions)}" : null);
        AutomationProperties.SetAutomationId(busiest, "more-usage.tile.peak");
        col.Children.Add(CommandCenterPage.TileRow(tokens, sessions, cost, busiest));
        if (usage.Daily.Count > 0) col.Children.Add(ChartCard(usage));
        var pair = new Grid { ColumnSpacing = 12 };
        var cards = new List<UIElement>();
        if (usage.Models.Count > 0) cards.Add(ModelsCard(usage));
        if (usage.Skills.Count > 0) cards.Add(SkillsCard(usage));
        for (var i = 0; i < cards.Count; i++)
        {
            pair.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn((FrameworkElement)cards[i], i);
            pair.Children.Add(cards[i]);
        }
        if (cards.Count > 0) col.Children.Add(pair);
        return scroll;
    }

    private FrameworkElement Headline(UsagePageModel m)
    {
        var g = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 2, 0, 2) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new StackPanel { Spacing = 1 };
        var title = Text(UsageFormat.Period(m.ShownDays), 18, bold: true);
        title.FontWeight = FontWeights.Bold;
        AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        words.Children.Add(title);
        words.Children.Add(Text("Every bot on this gateway, together.", 12, secondary: true));
        if (m.RefreshFailed)
        {
            var r = Text(m.RefreshFailedText, 11.5);
            r.Foreground = new SolidColorBrush(Orange);
            r.VerticalAlignment = VerticalAlignment.Center;
            var again = new Button { Content = InsightsWire.TryAgain };
            again.Click += (_, _) => m.Retry();
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { r, again } };
            AutomationProperties.SetAutomationId(line, "more-usage.refresh-failed");
            words.Children.Add(line);
        }
        g.Children.Add(words);
        if (m.Busy)
        {
            var ring = new ProgressRing { IsActive = true, Width = 14, Height = 14, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(ring, 1);
            g.Children.Add(ring);
        }
        var seg = Segmented("Period", UsageFormat.Periods.Select(d => ($"{d} Days", (object)d)).ToList(), m.Days, v => m.SetDays((int)v), 276);
        AutomationProperties.SetAutomationId(seg, "more-usage.period");
        AutomationProperties.SetItemStatus(seg, $"{m.Days} Days");
        seg.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(seg, 2);
        g.Children.Add(seg);
        return g;
    }

    /// A segmented switch (HQSegmentedPicker): equal segments in a rounded track, the chosen one raised.
    internal static FrameworkElement Segmented(string name, IReadOnlyList<(string Title, object Value)> options, object selected, Action<object> pick, double width)
    {
        var grid = new Grid { Width = width, Padding = new Thickness(2), ColumnSpacing = 2 };
        var track = new Border
        {
            CornerRadius = new CornerRadius(8), Background = Brush("ControlAltFillColorSecondaryBrush"),
            BorderBrush = Brush("ControlStrokeColorDefaultBrush"), BorderThickness = new Thickness(1), Child = grid,
        };
        for (var i = 0; i < options.Count; i++)
        {
            var (title, value) = options[i];
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var on = Equals(value, selected);
            var b = new ToggleButton
            {
                Content = title, IsChecked = on, HorizontalAlignment = HorizontalAlignment.Stretch, FontSize = 11.5,
                Padding = new Thickness(5, 2, 5, 2), CornerRadius = new CornerRadius(6), MinHeight = 24,
            };
            if (!on) { b.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); b.BorderThickness = new Thickness(0); }
            b.Click += (_, _) => { b.IsChecked = true; if (!on) pick(value); };
            AutomationProperties.SetName(b, title);
            Grid.SetColumn(b, i);
            grid.Children.Add(b);
        }
        AutomationProperties.SetName(track, name);
        return track;
    }

    private FrameworkElement ChartCard(UsageReport usage)
    {
        var chart = new UsageChart(usage, _sessions, split: true, dayFormat: "MMM d", desiredTicks: 8) { Height = 232 };
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
        void FillHeading()
        {
            heading.Children.Clear();
            if (_hovered is { } day)
                heading.Children.Add(Text($"{day.Date.ToString("MMM d", CultureInfo.CurrentCulture)} · {UsageFormat.Compact(day.Tokens)} tokens · {UsageFormat.Sessions(day.Sessions)}", 11.5, wrap: false));
            else if (!_sessions)
            {
                heading.Children.Add(Key("Read", 1.0));
                heading.Children.Add(Key("Written", 0.45));
            }
        }
        chart.Hovered += day => { _hovered = day; FillHeading(); };
        FillHeading();
        var metric = Segmented("Show", [("Tokens", (object)false), ("Sessions", true)], _sessions, v => { _sessions = (bool)v; _hovered = null; Render(); }, 180);
        AutomationProperties.SetAutomationId(metric, "more-usage.metric");
        return CommandCenterPage.DashCard(_sessions ? "Daily Sessions" : "Daily Tokens", chart, heading, metric);
    }

    private static FrameworkElement Key(string word, double opacity)
    {
        var swatch = new Rectangle { Width = 9, Height = 9, RadiusX = 2, RadiusY = 2, Fill = Brush("AccentFillColorDefaultBrush"), Opacity = opacity, VerticalAlignment = VerticalAlignment.Center };
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, Children = { swatch, Text(word, 11.5, secondary: true, wrap: false) } };
    }

    private static FrameworkElement ModelsCard(UsageReport usage)
    {
        var rows = usage.Models.Take(12).ToList();
        var top = Math.Max(1, rows.Max(r => r.Tokens));
        var all = Math.Max(1, usage.Models.Sum(r => r.Tokens));
        var stack = new StackPanel { Spacing = 9 };
        foreach (var r in rows)
        {
            var percent = (int)Math.Round((double)r.Tokens / all * 100, MidpointRounding.AwayFromZero);
            var parts = new List<string>();
            if (r.Sessions is { } s) parts.Add(UsageFormat.Sessions(s));
            if (r.Cost is { } c) parts.Add(UsageFormat.Cost(c));
            parts.Add($"{percent}% of tokens");
            var share = ShareRow(r.Id, UsageFormat.Compact(r.Tokens), (double)r.Tokens / top, string.Join(" · ", parts));
            AutomationProperties.SetName(share, $"{r.Id}, {UsageFormat.Compact(r.Tokens)} tokens, {UsageFormat.Sessions(r.Sessions)}");
            stack.Children.Add(share);
        }
        var count = Text($"{usage.Models.Count} {(usage.Models.Count == 1 ? "model" : "models")}", 11.5, secondary: true, wrap: false);
        return CommandCenterPage.DashCard("By Model", stack, count);
    }

    private static FrameworkElement SkillsCard(UsageReport usage)
    {
        var rows = usage.Skills.Take(12).ToList();
        var top = Math.Max(1, rows.Max(r => r.Count));
        var stack = new StackPanel { Spacing = 9 };
        foreach (var r in rows) stack.Children.Add(ShareRow(r.Id, UsageFormat.Actions(r.Count), (double)r.Count / top, null));
        return CommandCenterPage.DashCard("Top Skills", stack, Text("by how often bots used them", 11.5, secondary: true, wrap: false));
    }

    /// One row of a share list: its name and number, a bar as long as its share of the largest, a line under it.
    private static FrameworkElement ShareRow(string name, string value, double part, string? note)
    {
        var head = new Grid { ColumnSpacing = 10 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(Text(name, 13, wrap: false));
        var v = Text(value, 13, wrap: false);
        Grid.SetColumn(v, 1);
        head.Children.Add(v);
        var bar = new Grid { Height = 5 };
        bar.Children.Add(new Border { CornerRadius = new CornerRadius(2.5), Background = Brush("DividerStrokeColorDefaultBrush") });
        var fill = new Border { CornerRadius = new CornerRadius(2.5), Background = Brush("AccentFillColorDefaultBrush"), HorizontalAlignment = HorizontalAlignment.Left, MinWidth = 6 };
        bar.SizeChanged += (_, e) => fill.Width = Math.Max(6, e.NewSize.Width * Math.Clamp(part, 0, 1));
        bar.Children.Add(fill);
        var panel = new StackPanel { Spacing = 4, Children = { head, bar } };
        if (note != null) panel.Children.Add(Text(note, 11, secondary: true, wrap: false));
        AutomationProperties.SetName(panel, $"{name}, {value}");
        return panel;
    }
}

/// "Daily Tokens": a bar a day on a Canvas (the Mac's Swift Charts continuous date axis). `split`: a day's tokens
/// read (solid) under written (faded); `sessions`: sessions instead. Bars are positioned proportionally by calendar
/// day span via `UsageChartLayout`, and hovering an empty gap day clears hover.
internal sealed partial class UsageChart : UserControl
{
    private readonly UsageReport _report;
    private readonly bool _sessions, _split;
    private readonly string _dayFormat;
    private readonly int _ticks;
    private readonly Canvas _canvas = new();
    private int _hover = -1;
    private UsageChartLayout _layout = UsageChartLayout.Empty;
    public event Action<UsageReport.Day?>? Hovered;

    public UsageChart(UsageReport report, bool sessions, bool split, string dayFormat, int desiredTicks)
    {
        _report = report; _sessions = sessions; _split = split; _dayFormat = dayFormat; _ticks = desiredTicks;
        Content = _canvas;
        AutomationProperties.SetName(this, report.ChartSummary());
        AutomationProperties.SetAutomationId(this, "more-usage.chart");
        SizeChanged += (_, _) => Draw();
        PointerMoved += (_, e) =>
        {
            var x = e.GetCurrentPoint(_canvas).Position.X;
            var i = _layout.HitTest(x);
            if (i < 0 || i >= _report.Daily.Count) i = -1;
            if (i == _hover) return;
            _hover = i;
            Draw();
            Hovered?.Invoke(i >= 0 ? _report.Daily[i] : null);
        };
        PointerExited += (_, _) => { if (_hover < 0) return; _hover = -1; Draw(); Hovered?.Invoke(null); };
    }

    private long Value(UsageReport.Day d) => _sessions ? d.Sessions : d.Tokens;

    /// A "nice" axis top and step for `max` (1, 2, 2.5, 5 × 10ⁿ), about four lines.
    internal static (double Top, double Step) Axis(double max)
    {
        if (max <= 0) return (1, 1);
        var rough = max / 4;
        var mag = Math.Pow(10, Math.Floor(Math.Log10(rough)));
        var step = new[] { 1, 2, 2.5, 5, 10 }.Select(f => f * mag).First(s => s >= rough);
        return (Math.Ceiling(max / step) * step, step);
    }

    private void Draw()
    {
        _canvas.Children.Clear();
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0 || _report.Daily.Count == 0) { _layout = UsageChartLayout.Empty; return; }
        var (top, step) = Axis(_report.Daily.Max(Value));
        var labelBrush = Kit.Brush("TextFillColorSecondaryBrush");
        var gridBrush = Kit.Brush("DividerStrokeColorDefaultBrush");
        const double bottomRoom = 18, leftRoom = 42;
        var plotH = h - bottomRoom;
        var plotW = w - leftRoom;
        if (plotW <= 0 || plotH <= 0) { _layout = UsageChartLayout.Empty; return; }
        for (var v = 0.0; v <= top + step / 2; v += step)
        {
            var y = plotH - v / top * plotH;
            _canvas.Children.Add(new Line { X1 = leftRoom, X2 = w, Y1 = y, Y2 = y, Stroke = gridBrush, StrokeThickness = 1 });
            var label = new TextBlock { Text = UsageFormat.Compact((long)v), FontSize = 10.5, Foreground = labelBrush, Width = leftRoom - 6, TextAlignment = TextAlignment.Right };
            Canvas.SetLeft(label, 0);
            Canvas.SetTop(label, y - 7);
            _canvas.Children.Add(label);
        }
        _layout = UsageChartLayout.Compute(_report.Daily, leftRoom, plotW, _ticks);
        var accent = Kit.Brush("AccentFillColorDefaultBrush");
        foreach (var bar in _layout.Bars)
        {
            var d = _report.Daily[bar.DayIndex];
            var dim = _hover < 0 || _hover == bar.DayIndex ? 1.0 : 0.35;
            void Bar(double from, double to, double opacity)
            {
                if (to <= from) return;
                var y1 = plotH - to / top * plotH;
                var y0 = plotH - from / top * plotH;
                var r = new Rectangle { Width = bar.Width, Height = Math.Max(0, y0 - y1), Fill = accent, Opacity = opacity * dim, RadiusX = 2, RadiusY = 2 };
                Canvas.SetLeft(r, bar.X);
                Canvas.SetTop(r, y1);
                _canvas.Children.Add(r);
            }
            if (_sessions) Bar(0, d.Sessions, 1);
            else if (_split) { Bar(0, d.Input, 1); Bar(d.Input, d.Input + d.Output, 0.45); }
            else Bar(0, d.Tokens, 1);
        }
        // Proportional calendar-date ticks along the X axis.
        foreach (var tick in _layout.Ticks)
        {
            var label = new TextBlock { Text = tick.Date.ToString(_dayFormat, CultureInfo.CurrentCulture), FontSize = 10.5, Foreground = labelBrush };
            Canvas.SetLeft(label, Math.Min(tick.X, Math.Max(leftRoom, w - 42)));
            Canvas.SetTop(label, plotH + 2);
            _canvas.Children.Add(label);
        }
    }
}
