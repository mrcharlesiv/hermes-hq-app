using System.Globalization;
using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using Windows.ApplicationModel.DataTransfer;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// Multi-week strip at the top of Upcoming (`App/Pages/Tasks/TasksViewController.swift`, commit 36659bce1):
/// `weekOffset` 0..52, prev/next week buttons, Today reset pill, 7 day tiles with busy dots, single-day filter toggle,
/// and drag-drop target to reschedule a task onto any day (preserving its clock time).
internal sealed class TodoWeekStripView : UserControl
{
    public const int MaxWeekOffset = 52;
    public const string DragPrefix = "hq-task:";
    private static readonly CultureInfo En = CultureInfo.GetCultureInfo("en-US");

    private readonly StackPanel _root = new() { Spacing = 8 };
    private readonly TextBlock _rangeTitle = Text("", 13, bold: true);
    private readonly Button _todayPill;
    private readonly Button _prevBtn;
    private readonly Button _nextBtn;
    private readonly Grid _daysGrid = new() { ColumnSpacing = 4 };

    public int WeekOffset { get; private set; }
    public string? PickedDay { get; private set; }

    public Action<int>? OnWeekOffsetChanged { get; set; }
    public Action<string?>? OnPickDay { get; set; }
    public Func<string?>? GetDraggingTaskId { get; set; }
    public Action<string, DateTimeOffset>? OnDropTaskOnDay { get; set; }

    public TodoWeekStripView()
    {
        IsTabStop = false;
        Margin = new Thickness(0, 4, 0, 8);
        AutomationProperties.SetAutomationId(this, "tasks.upcoming.week-strip");

        _todayPill = Quiet(TasksCopy.Today, () =>
        {
            WeekOffset = 0;
            PickedDay = null;
            OnWeekOffsetChanged?.Invoke(0);
            OnPickDay?.Invoke(null);
        });
        _todayPill.Padding = new Thickness(8, 2, 8, 2);
        AutomationProperties.SetAutomationId(_todayPill, "tasks.upcoming.today-pill");

        _prevBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE76B", FontSize = 12 },
            Style = Style("QuietButtonStyle"),
            Padding = new Thickness(6, 4, 6, 4),
        };
        AutomationProperties.SetName(_prevBtn, "Previous Week");
        AutomationProperties.SetAutomationId(_prevBtn, "tasks.upcoming.prev-week");
        _prevBtn.Click += (_, _) =>
        {
            if (WeekOffset <= 0) return;
            WeekOffset--;
            OnWeekOffsetChanged?.Invoke(WeekOffset);
        };

        _nextBtn = new Button
        {
            Content = new FontIcon { Glyph = "\uE76C", FontSize = 12 },
            Style = Style("QuietButtonStyle"),
            Padding = new Thickness(6, 4, 6, 4),
        };
        AutomationProperties.SetName(_nextBtn, "Next Week");
        AutomationProperties.SetAutomationId(_nextBtn, "tasks.upcoming.next-week");
        _nextBtn.Click += (_, _) =>
        {
            if (WeekOffset >= MaxWeekOffset) return;
            WeekOffset++;
            OnWeekOffsetChanged?.Invoke(WeekOffset);
        };

        var header = new Grid { ColumnSpacing = 6 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _rangeTitle.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(_rangeTitle);

        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        controls.Children.Add(_todayPill);
        controls.Children.Add(_prevBtn);
        controls.Children.Add(_nextBtn);
        Grid.SetColumn(controls, 1);
        header.Children.Add(controls);

        for (var i = 0; i < 7; i++)
            _daysGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        _root.Children.Add(header);
        _root.Children.Add(_daysGrid);
        Content = new Border
        {
            Padding = new Thickness(10, 8, 10, 10),
            CornerRadius = new CornerRadius(10),
            Background = Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
            Child = _root,
        };
    }

    public void Render(int weekOffset, string? pickedDay, IReadOnlySet<string> busyDays, DateTimeOffset now, TimeZoneInfo zone)
    {
        WeekOffset = Math.Clamp(weekOffset, 0, MaxWeekOffset);
        PickedDay = pickedDay;

        var todayLocal = TodoDates.LocalDay(now, zone);
        var startLocal = todayLocal.AddDays(WeekOffset * 7);
        var dates = new List<DateTimeOffset>(7);
        for (var i = 0; i < 7; i++)
            dates.Add(TodoDates.StartOfDay(startLocal.AddDays(i), zone));

        _rangeTitle.Text = TodoViews.WeekRangeTitle(dates, zone);
        _prevBtn.IsEnabled = WeekOffset > 0;
        _nextBtn.IsEnabled = WeekOffset < MaxWeekOffset;
        _todayPill.Visibility = WeekOffset > 0 || pickedDay != null ? Visibility.Visible : Visibility.Collapsed;

        _daysGrid.Children.Clear();
        var todayKey = TodoViews.DayKey(todayLocal);

        for (var i = 0; i < 7; i++)
        {
            var day = dates[i];
            var local = TodoDates.LocalDay(day, zone);
            var key = TodoViews.DayKey(local);
            var isToday = key == todayKey;
            var isPicked = key == pickedDay;
            var busy = busyDays.Contains(key);

            var stack = new StackPanel { Spacing = 3, HorizontalAlignment = HorizontalAlignment.Center };
            stack.Children.Add(new TextBlock
            {
                Text = local.ToString("ddd", En).ToUpperInvariant(),
                FontSize = 10.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = isPicked ? Brush("TextOnAccentFillColorPrimaryBrush") : isToday ? Accent : Secondary,
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            stack.Children.Add(new TextBlock
            {
                Text = local.Day.ToString(CultureInfo.InvariantCulture),
                FontSize = 14,
                FontWeight = isPicked || isToday ? FontWeights.Bold : FontWeights.SemiBold,
                Foreground = isPicked ? Brush("TextOnAccentFillColorPrimaryBrush") : isToday ? Accent : Brush("TextFillColorPrimaryBrush"),
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            stack.Children.Add(new Ellipse
            {
                Width = 5,
                Height = 5,
                Fill = busy ? (isPicked ? Brush("TextOnAccentFillColorPrimaryBrush") : Accent) : Solid(Microsoft.UI.Colors.Transparent),
                HorizontalAlignment = HorizontalAlignment.Center,
            });

            var normalBg = isPicked ? Brush("AccentFillColorDefaultBrush")
                : isToday ? AccentWash(0.10)
                : Solid(Microsoft.UI.Colors.Transparent);

            var tile = new Border
            {
                Child = stack,
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(4, 6, 4, 6),
                Background = normalBg,
                BorderThickness = new Thickness(1),
                BorderBrush = Solid(Microsoft.UI.Colors.Transparent),
                AllowDrop = true,
            };

            var btn = new Button
            {
                Content = tile,
                Padding = new Thickness(0),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Style = Style("QuietButtonStyle"),
            };
            AutomationProperties.SetName(btn, local.ToString("dddd, MMMM d", En) + (busy ? ", has tasks" : ""));
            AutomationProperties.SetAutomationId(btn, "tasks.upcoming.day." + key);
            var capturedKey = key;
            var capturedDay = day;
            btn.Click += (_, _) => OnPickDay?.Invoke(PickedDay == capturedKey ? null : capturedKey);

            // Drag-drop rescheduling onto this day tile.
            tile.DragOver += (_, e) =>
            {
                var taskId = GetDraggingTaskId?.Invoke();
                if (taskId == null && !e.DataView.Contains(StandardDataFormats.Text)) return;
                e.AcceptedOperation = DataPackageOperation.Move;
                e.DragUIOverride.Caption = "Move to " + local.ToString("ddd, MMM d", En);
                e.DragUIOverride.IsCaptionVisible = true;
                tile.BorderBrush = Accent;
                tile.Background = AccentWash(0.20);
                e.Handled = true;
            };
            tile.DragLeave += (_, _) =>
            {
                tile.BorderBrush = Solid(Microsoft.UI.Colors.Transparent);
                tile.Background = normalBg;
            };
            tile.Drop += async (_, e) =>
            {
                tile.BorderBrush = Solid(Microsoft.UI.Colors.Transparent);
                tile.Background = normalBg;
                var taskId = GetDraggingTaskId?.Invoke();
                if (taskId == null && e.DataView.Contains(StandardDataFormats.Text))
                {
                    try
                    {
                        var text = await e.DataView.GetTextAsync();
                        if (text.StartsWith(DragPrefix, StringComparison.Ordinal) && text.Length > DragPrefix.Length)
                            taskId = text[DragPrefix.Length..];
                    }
                    catch (Exception) { }
                }
                if (string.IsNullOrEmpty(taskId)) return;
                e.Handled = true;
                OnDropTaskOnDay?.Invoke(taskId, capturedDay);
            };

            Grid.SetColumn(btn, i);
            _daysGrid.Children.Add(btn);
        }
    }
}
