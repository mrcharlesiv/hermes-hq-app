namespace Hermes.Core.Insights;

/// Calendar-day proportional bar layout and hit-testing for the Usage daily chart.
/// Matches Mac's Swift Charts continuous date axis so sparse or nonconsecutive dates are spaced
/// proportionally by calendar day span (e.g. a 1-day gap vs a 27-day gap) rather than uniformly by array index.
public sealed class UsageChartLayout
{
    public readonly record struct Bar(int DayIndex, DateTime Date, int DayOffset, double X, double CenterX, double Width);
    public readonly record struct Tick(DateTime Date, int DayOffset, double X, double CenterX);

    public DateTime FirstDay { get; }
    public DateTime LastDay { get; }
    public int TotalSlots { get; }
    public double PlotLeft { get; }
    public double PlotWidth { get; }
    public double SlotWidth { get; }
    public double BarWidth { get; }
    public IReadOnlyList<Bar> Bars { get; }
    public IReadOnlyList<Tick> Ticks { get; }

    private readonly Dictionary<int, int> _dayIndexBySlot;

    private UsageChartLayout(DateTime firstDay, DateTime lastDay, int totalSlots, double plotLeft, double plotWidth,
        double slotWidth, double barWidth, List<Bar> bars, List<Tick> ticks, Dictionary<int, int> dayIndexBySlot)
    {
        FirstDay = firstDay;
        LastDay = lastDay;
        TotalSlots = totalSlots;
        PlotLeft = plotLeft;
        PlotWidth = plotWidth;
        SlotWidth = slotWidth;
        BarWidth = barWidth;
        Bars = bars;
        Ticks = ticks;
        _dayIndexBySlot = dayIndexBySlot;
    }

    public static readonly UsageChartLayout Empty = new(DateTime.MinValue, DateTime.MinValue, 0, 0, 0, 0, 0, [], [], []);

    /// Computes calendar-day bar positions and X-axis ticks for `daily` within `[plotLeft, plotLeft + plotWidth]`.
    public static UsageChartLayout Compute(IReadOnlyList<UsageReport.Day> daily, double plotLeft, double plotWidth, int desiredTicks)
    {
        if (daily.Count == 0 || plotWidth <= 0 || !double.IsFinite(plotWidth) || !double.IsFinite(plotLeft))
            return Empty;

        var firstDay = daily[0].Date.Date;
        var lastDay = firstDay;
        for (var i = 1; i < daily.Count; i++)
        {
            var d = daily[i].Date.Date;
            if (d < firstDay) firstDay = d;
            if (d > lastDay) lastDay = d;
        }

        var spanDays = Math.Max(0, (int)(lastDay - firstDay).TotalDays);
        var totalSlots = spanDays + 1;
        var slotWidth = plotWidth / totalSlots;
        // Fill ~70% of each calendar-day slot (matching dense charts), while capping very wide single/few-day bars.
        var maxBarWidth = Math.Min(64.0, Math.Max(2.0, plotWidth * 0.55));
        var barWidth = Math.Clamp(slotWidth * 0.7, 1.0, maxBarWidth);

        var bars = new List<Bar>(daily.Count);
        var bySlot = new Dictionary<int, int>(daily.Count);
        for (var i = 0; i < daily.Count; i++)
        {
            var date = daily[i].Date.Date;
            var offset = Math.Max(0, (int)(date - firstDay).TotalDays);
            var centerX = plotLeft + (offset + 0.5) * slotWidth;
            var x = centerX - barWidth / 2.0;
            bars.Add(new Bar(i, date, offset, x, centerX, barWidth));
            bySlot[offset] = i;
        }

        var ticks = new List<Tick>();
        var tickCount = Math.Max(1, desiredTicks);
        var every = Math.Max(1, (int)Math.Ceiling((double)totalSlots / tickCount));
        for (var offset = 0; offset < totalSlots; offset += every)
        {
            var x = plotLeft + offset * slotWidth;
            var centerX = plotLeft + (offset + 0.5) * slotWidth;
            ticks.Add(new Tick(firstDay.AddDays(offset), offset, x, centerX));
        }

        return new UsageChartLayout(firstDay, lastDay, totalSlots, plotLeft, plotWidth, slotWidth, barWidth, bars, ticks, bySlot);
    }

    /// Returns the index into the original `daily` list for pointer coordinate `x`, or `-1` when `x` is
    /// outside the plot area or falls on an empty calendar gap day with no recorded bar.
    public int HitTest(double x)
    {
        if (TotalSlots <= 0 || SlotWidth <= 0 || !double.IsFinite(x)) return -1;
        if (x < PlotLeft || x >= PlotLeft + PlotWidth) return -1;
        var slot = (int)Math.Floor((x - PlotLeft) / SlotWidth);
        if (slot < 0 || slot >= TotalSlots) return -1;
        return _dayIndexBySlot.TryGetValue(slot, out var dayIndex) ? dayIndex : -1;
    }
}
