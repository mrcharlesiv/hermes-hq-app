using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

public class SettingsFileActionLayoutTests
{
    private static SettingsFileActionMetrics Metrics(int scale = 100, bool desktop = false, bool main = false) =>
        SettingsFileActionMetrics.For(new ThemeState { UiScalePercent = scale, DesktopLook = desktop }, main);

    [Theory]
    [InlineData(619, 618)] [InlineData(618, 619)]
    [InlineData(626, 612)] [InlineData(612, 626)]
    public void RepeatedOfferUsesTheAllocatedCardForHeightRowsAndScrollRange(double offer, double slot)
    {
        var view = new SettingsFileActionViewport();
        var m = SettingsFileActionMetrics.For(ThemeState.Default, false, 1, 3);
        SettingsFileActionRows Fit(double width) => m.Fit(width, 128 + m.Gap + 130, 32, 168 + m.Gap + 139, 32);
        // The wrapper lives inside the two native card edges. A new card initially has only the proposal.
        offer -= 2; slot -= 2;
        var first = view.Measure(offer);
        Assert.Equal((offer, offer), first);
        Assert.NotEqual(Fit(offer).Height, Fit(slot).Height);
        Assert.True(view.Arrange(slot, slot));
        var settled = view.Measure(offer);
        Assert.Equal((slot, slot), settled);
        Assert.Equal(Fit(slot), Fit(settled.Viewport));
        Assert.False(view.Arrange(slot, slot)); // no perpetual invalidation
        Assert.Equal(0, Math.Max(0, Fit(settled.Viewport).Width - settled.Viewport));
        Assert.Equal((offer + 1, offer + 1), view.Measure(offer + 1));
        Assert.Equal((offer + 1, offer + 1), view.Measure(offer + 1)); // still no allocation for that offer
    }

    [Fact]
    public void TemplateViewportCanChangeWithoutAnotherOuterWidthOrContentExtent()
    {
        var view = new SettingsFileActionViewport();
        Assert.Equal((600d, 600d), view.Measure(600));
        foreach (var viewport in new[] { 588d, 600, 0, 599.25 })
        {
            Assert.True(view.Arrange(600, viewport));
            Assert.Equal((600d, viewport), view.Measure(600));
            Assert.False(view.Arrange(600, viewport));
        }
        Assert.Equal((double.PositiveInfinity, double.PositiveInfinity), view.Measure(double.PositiveInfinity));
        Assert.True(view.Arrange(0, 0)); // a real zero allocation, not an unknown width
        Assert.Equal((0d, 0d), view.Measure(double.PositiveInfinity));
    }

    [Fact]
    public void EachPairKeepsItsNaturalWidthAndThereIsNoTrailingGap()
    {
        var m = Metrics();
        // The four native Windows controls measured in the 844 × 631 connected baseline. A third button
        // fits beside the first two, but the whole second logical group does not.
        var first = 128 + m.Gap + 130;
        var second = 168 + m.Gap + 139;
        var threshold = first + m.Gap + second;
        foreach (double offer in new[] { 0, 120, second - 1, second, 496, threshold - 0.25, threshold, threshold + 1, double.PositiveInfinity })
        {
            var p = m.Fit(offer + 2 * m.SideInset, first, 32, second, 32);
            var single = offer >= threshold;
            Assert.Equal(2 * m.SideInset + (single ? threshold : second), p.Width, 6);
            Assert.Equal(2 * m.VerticalInset + (single ? 32 : 64 + m.RowGap), p.Height, 6);
            Assert.Equal(m.SideInset + (single ? first + m.Gap : 0), p.SecondX, 6);
            Assert.Equal(m.VerticalInset + (single ? 0 : 32 + m.RowGap), p.SecondY, 6);
            Assert.Equal(m.VerticalInset, p.FirstY);
        }
    }

    [Theory]
    [InlineData(340, 26, 105, 40)]
    [InlineData(100, 46, 940, 28)]
    [InlineData(312.5, 24.5, 208.25, 25.5)]
    public void StackedGroupsAreLeadingAndInlineGroupsCenterEvenWithUnequalHeights(double a, double ah, double b, double bh)
    {
        var m = Metrics();
        var stacked = m.Fit(2 * m.SideInset + Math.Max(a, b), a, ah, b, bh);
        Assert.Equal(2 * m.SideInset + Math.Max(a, b), stacked.Width, 6);
        Assert.Equal(2 * m.VerticalInset + ah + m.RowGap + bh, stacked.Height, 6);
        Assert.Equal(m.SideInset, stacked.SecondX);
        Assert.Equal(m.VerticalInset, stacked.FirstY);
        Assert.Equal(m.VerticalInset + ah + m.RowGap, stacked.SecondY, 6);
        var inline = m.Fit(2 * m.SideInset + a + m.Gap + b, a, ah, b, bh);
        Assert.Equal(2 * m.SideInset + a + m.Gap + b, inline.Width, 6);
        Assert.Equal(2 * m.VerticalInset + Math.Max(ah, bh), inline.Height, 6);
        Assert.Equal(inline.FirstY + ah / 2, inline.SecondY + bh / 2);
        Assert.Equal(m.SideInset + a + m.Gap, inline.SecondX, 6);
    }

    [Theory]
    [InlineData(false, 171, 171, 225, 186, 783)]
    [InlineData(true, 172, 172, 226, 187, 787)]
    public void DefaultSizeSwitchesAtTheMeasuredMacContentWidth(bool desktop, int export, int import, int clear, int reset, int switchAt)
    {
        var m = Metrics(desktop: desktop);
        double files = (export + import) * m.Unit + m.Gap;
        double resets = (clear + reset) * m.Unit + m.Gap;
        foreach (var delta in new[] { -1, 0, 1 })
        {
            double viewport = 2 * m.SideInset + (switchAt + delta) * m.Unit;
            var p = m.Fit(viewport, files, 32 * m.Unit, resets, 32 * m.Unit);
            Assert.Equal(delta >= 0, p.SecondX > m.SideInset);
        }
    }

    [Theory]
    [InlineData(100, false, 1, 3)]
    [InlineData(160, true, 1, 3)]
    [InlineData(80, true, 2, 4)]
    public void NativeCardBorderCountsTowardTheInsetButNeverClipsTheFocusRing(int scale, bool main, double edge, double focus)
    {
        var m = SettingsFileActionMetrics.For(new ThemeState { UiScalePercent = scale }, main, edge, focus);
        Assert.Equal(Math.Max(edge + focus, 20 * m.Unit), edge + m.SideInset, 6);
        Assert.Equal(Math.Max(edge + focus, 8 * m.Unit), edge + m.VerticalInset, 6);
    }

    [Fact]
    public void RoundingCanNeverMakeTheButtonsOverlap()
    {
        // Very long content: a single float step can be wider than the gap. The viewport must
        // scroll or stack, not draw one of the measured groups over the other.
        var m = Metrics();
        float viewport = 1 << 28;
        float pair = viewport / 2 - 8;
        Assert.Equal(m.SideInset, m.Fit(viewport, pair, 30, pair, 30).SecondX);
    }

    [Fact]
    public void TheRepresentedExtentFitsAndThePrecedingWinUiWidthDoesNot()
    {
        var m = Metrics(125, main: true);
        double pair = (float)(137.25 + m.Gap + 128.25);
        var nativeExtent = (float)(pair + m.Gap + pair + 2 * m.SideInset);
        // Size.Width is a Single in WinRT. The exposed full width is exactly enough, even when
        // subtracting the margins again leaves the inner offer a fraction of an ULP too small.
        double SecondX(float width) => m.Fit(width, pair, 32, pair, 32).SecondX;
        Assert.True(SecondX(nativeExtent) > m.SideInset);
        Assert.Equal(m.SideInset, SecondX(MathF.BitDecrement(nativeExtent)));
    }

    [Fact]
    public void IndividuallyMeasuredGroupsFitAtTheConvertedSwitchWithoutAHorizontalOverflow()
    {
        // At 150%, ordinary Mac Look measures 237, 237, 317 and 258 UIKit points. WinRT returns
        // single-precision sizes for each button and again for each pair; the viewport rounds separately.
        var m = Metrics(150, main: true);
        float Width(double points) => (float)(points * m.Unit);
        var files = (float)(Width(237) + m.Gap + Width(237));
        var resets = (float)(Width(317) + m.Gap + Width(258));
        var viewport = Width(1079 + 40);
        var at = m.Fit(viewport, files, 30, resets, 30);
        Assert.True(at.SecondX > m.SideInset);
        Assert.True(at.Width <= viewport);
        Assert.Equal(viewport, at.SecondX + resets + m.SideInset, 6);
        Assert.Equal(m.SideInset, m.Fit(MathF.BitDecrement(viewport), files, 30, resets, 30).SecondX);
    }

    [Theory]
    // Mac 1245 HQFont.body (UIKit points), obtained at the default Dynamic Type size in an offscreen Catalyst host.
    [InlineData(80, 15.5, 15.5)] [InlineData(90, 17.5, 17.5)] [InlineData(100, 19.5, 19.5)]
    [InlineData(110, 21.5, 21.5)] [InlineData(125, 24.5, 24.5)] [InlineData(150, 29.5, 29.5)] [InlineData(160, 31.5, 31)]
    public void OnlyTheBodyScalesAndTheHostTransformIsCountedOnce(int scale, double ordinary, double desktop)
    {
        foreach (var look in new[] { false, true })
        foreach (var main in new[] { false, true })
        {
            var m = Metrics(scale, look, main);
            var host = main ? scale / 100d : 1;
            Assert.Equal((look ? desktop : ordinary) * .77, m.FontSize * host, 6);
            Assert.Equal(12 * .77, m.ButtonSide * host, 6);
            Assert.Equal(4 * .77, m.ButtonVertical * host, 6);
            Assert.Equal(10 * .77, m.Gap * host, 6);
            Assert.Equal(8 * .77, m.RowGap * host, 6);
        }
    }
}
