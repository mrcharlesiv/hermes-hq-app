using Hermes.Core.Insights;
using Xunit;

namespace Hermes.Core.Tests.Insights;

public class UsageChartLayoutTests
{
    private static UsageReport.Day Day(int year, int month, int day, long input = 1000, long output = 500, long sessions = 2) =>
        new($"{year:D4}-{month:D2}-{day:D2}", new DateTime(year, month, day), input, output, sessions);

    [Fact]
    public void SparseDatesSpaceProportionallyByCalendarDaysAndClearHoverInGaps()
    {
        // Oct 26, Oct 27 (1-day gap), Nov 23 (27-day gap): 29 calendar days total (matching Mac build 1274 proof).
        var daily = new[]
        {
            Day(2026, 10, 26, 5000, 1000, 3),
            Day(2026, 10, 27, 4000, 1000, 2),
            Day(2026, 11, 23, 6000, 2000, 4),
        };

        var layout = UsageChartLayout.Compute(daily, plotLeft: 42, plotWidth: 667, desiredTicks: 8);

        Assert.Equal(29, layout.TotalSlots);
        Assert.Equal(3, layout.Bars.Count);
        var gap1 = layout.Bars[1].CenterX - layout.Bars[0].CenterX;
        var gap2 = layout.Bars[2].CenterX - layout.Bars[1].CenterX;
        Assert.Equal(27.0, gap2 / gap1, 6);
        Assert.InRange(gap1, 22.5, 23.5);
        Assert.InRange(gap2, 619.0, 623.0);

        // Hovering each bar's center hits its exact index.
        Assert.Equal(0, layout.HitTest(layout.Bars[0].CenterX));
        Assert.Equal(1, layout.HitTest(layout.Bars[1].CenterX));
        Assert.Equal(2, layout.HitTest(layout.Bars[2].CenterX));

        // Hovering empty gap days between Oct 27 and Nov 23 returns -1 (clears hover).
        var midGapX = (layout.Bars[1].CenterX + layout.Bars[2].CenterX) / 2.0;
        Assert.Equal(-1, layout.HitTest(midGapX));
        Assert.Equal(-1, layout.HitTest(layout.Bars[1].CenterX + layout.SlotWidth * 5));

        // Out-of-bounds pointer returns -1.
        Assert.Equal(-1, layout.HitTest(10));
        Assert.Equal(-1, layout.HitTest(42 + 667 + 1));
    }

    [Fact]
    public void ConsecutiveThreeDaysHaveEqualCenterSpacing()
    {
        var daily = new[]
        {
            Day(2026, 10, 26),
            Day(2026, 10, 27),
            Day(2026, 10, 28),
        };

        var layout = UsageChartLayout.Compute(daily, plotLeft: 42, plotWidth: 663, desiredTicks: 8);

        Assert.Equal(3, layout.TotalSlots);
        var gap1 = layout.Bars[1].CenterX - layout.Bars[0].CenterX;
        var gap2 = layout.Bars[2].CenterX - layout.Bars[1].CenterX;
        Assert.Equal(221.0, gap1, 6);
        Assert.Equal(221.0, gap2, 6);
        Assert.Equal(0, layout.HitTest(42 + 10));
        Assert.Equal(1, layout.HitTest(42 + 221 + 10));
        Assert.Equal(2, layout.HitTest(42 + 442 + 10));
    }

    [Fact]
    public void DenseThirtyDaysPlacesBarsAndTicksAcrossFullWidth()
    {
        var start = new DateTime(2026, 10, 1);
        var daily = Enumerable.Range(0, 30).Select(i => Day(start.AddDays(i).Year, start.AddDays(i).Month, start.AddDays(i).Day)).ToList();

        var layout = UsageChartLayout.Compute(daily, plotLeft: 40, plotWidth: 600, desiredTicks: 8);

        Assert.Equal(30, layout.TotalSlots);
        Assert.Equal(30, layout.Bars.Count);
        Assert.Equal(20.0, layout.SlotWidth, 6);
        Assert.Equal(14.0, layout.BarWidth, 6);
        Assert.InRange(layout.Ticks.Count, 6, 10);
        Assert.Equal(start, layout.Ticks[0].Date);
        for (var i = 0; i < 30; i++) Assert.Equal(i, layout.HitTest(layout.Bars[i].CenterX));
    }

    [Fact]
    public void SingleDayAndEmptyAndUnsortedInputsAreHandledCleanly()
    {
        var single = UsageChartLayout.Compute([Day(2026, 11, 1)], plotLeft: 40, plotWidth: 200, desiredTicks: 4);
        Assert.Equal(1, single.TotalSlots);
        Assert.Single(single.Bars);
        Assert.Equal(140.0, single.Bars[0].CenterX, 6);
        Assert.Equal(0, single.HitTest(140));
        Assert.Equal(-1, single.HitTest(39));

        var empty = UsageChartLayout.Compute([], plotLeft: 40, plotWidth: 200, desiredTicks: 4);
        Assert.Equal(0, empty.TotalSlots);
        Assert.Empty(empty.Bars);
        Assert.Equal(-1, empty.HitTest(100));

        var zeroWidth = UsageChartLayout.Compute([Day(2026, 11, 1)], plotLeft: 40, plotWidth: 0, desiredTicks: 4);
        Assert.Equal(0, zeroWidth.TotalSlots);

        // Unsorted input still maps HitTest back to the original DayIndex.
        var unsorted = new[] { Day(2026, 11, 10), Day(2026, 11, 1) };
        var uLayout = UsageChartLayout.Compute(unsorted, plotLeft: 0, plotWidth: 100, desiredTicks: 4);
        Assert.Equal(10, uLayout.TotalSlots);
        Assert.Equal(1, uLayout.HitTest(5));   // Nov 1 is at original index 1
        Assert.Equal(0, uLayout.HitTest(95));  // Nov 10 is at original index 0
        Assert.Equal(-1, uLayout.HitTest(50)); // Nov 6 is empty gap
    }
}
