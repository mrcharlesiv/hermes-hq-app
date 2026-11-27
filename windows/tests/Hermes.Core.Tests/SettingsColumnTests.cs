using Hermes.Core.Settings;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// The isolated Settings frame is NOT the frame ThemeService.ApplyScale transforms. Values below are layout DIPs;
/// rasterization happens after layout. Native pair 136/137 is a baseline, not a capture of these calculations.
public class SettingsColumnTests
{
    private static SettingsColumnLayout At(int percent = 100, bool desktop = false) =>
        new(ThemeState.Default with { UiScalePercent = percent, DesktopLook = desktop });

    [Theory]
    [InlineData(80, 166, 11.935)]
    [InlineData(90, 187, 13.475)]
    [InlineData(100, 208, 15.015)]
    [InlineData(110, 229, 16.555)]
    [InlineData(125, 260, 18.865)]
    [InlineData(150, 312, 22.715)]
    [InlineData(160, 333, 24.255)]
    public void OnlyTheUserSizedMeasuresGrow(int percent, int dividerX, double body)
    {
        var form = At(percent);
        Assert.Equal(dividerX, form.ColumnWidth(1));
        Assert.Equal(body, form.Body, 5);
        Assert.Equal(9.24, SettingsColumnLayout.ColumnInset, 5);
        Assert.Equal(15.4, SettingsColumnLayout.FormGutter, 5);
        Assert.Equal(23.1, SettingsColumnLayout.IconSlot, 5);
        Assert.Equal(SettingsColumnLayout.FormGutter, form.FormSide(240));
    }

    [Theory]
    [InlineData(844, 100, 1)]  // the connected reference
    [InlineData(677, 150, 1)]  // minimum outer frame minus the archived horizontal chrome
    [InlineData(650, 80, 1.25)]
    [InlineData(720, 125, 1.5)]
    [InlineData(1200, 100, 2)]
    [InlineData(1620, 150, 2)]
    public void PaneKeepsItsGutterAndCentersItsReadableCap(double client, int percent, double dpi)
    {
        var form = At(percent);
        var split = form.ColumnWidth(dpi);
        Assert.Equal(Math.Round(split * dpi), split * dpi, 8);
        Assert.Equal(1, SettingsColumnLayout.Hairline(dpi) * dpi, 8);
        var start = split + SettingsColumnLayout.Hairline(dpi);
        var pane = client - start;
        var side = form.FormSide(pane);
        var width = pane - 2 * side;
        var left = start + side;
        Assert.Equal(client - left - width, left - start, 7);
        Assert.InRange(left - start, SettingsColumnLayout.FormGutter - 1e-8, pane / 2);
        Assert.True(width > 0);
        if (client == 844)
        {
            Assert.InRange(left, 223, 225); // Mac painted x=[224,830); antialiasing/layout rounding within two pixels
            Assert.InRange(width, 604, 608);
            Assert.InRange(split - 2 * SettingsColumnLayout.ColumnInset, 189, 191); // search and category share this slot
        }
        if (client == 677) Assert.InRange(width, 332, 335);
        if (client == 1200) Assert.InRange(width, 636, 639);
    }

    [Fact]
    public void ReadabilityAndGuttersDoNotChangeWithTheLookButTypeFollowsItsOwnRole()
    {
        var plain = At(90);
        var desktop = At(90, desktop: true);
        Assert.Equal(plain.ColumnWidth(2), desktop.ColumnWidth(2));
        Assert.Equal(plain.FormSide(1200), desktop.FormSide(1200));
        Assert.Equal(10.395, plain.Footnote, 5);
        Assert.Equal(11.55, desktop.Footnote, 5);
        Assert.Equal(15.785, plain.GatewayIcon, 5);
    }

    [Theory]
    [InlineData(false, false, false)]
    [InlineData(false, false, true)]
    [InlineData(true, false, false)]
    [InlineData(true, false, true)]
    [InlineData(true, true, false)]
    [InlineData(true, true, true)]
    public void DividerAndSelectionResolveAgainstTheLookNotKeyboardFocus(bool desktop, bool appContrast, bool dark)
    {
        var state = ThemeState.Default with { DesktopLook = desktop, HighContrast = appContrast };
        var t = ThemeResolver.Resolve(state).Tokens(dark);
        var line = SettingsColumnLayout.PaneLine(t, desktop, dark);
        Assert.Equal(desktop ? (dark ? Rgba.White.Alpha(.1) : Rgba.Black.Alpha(.12)) : t.Separator, line);
        var mark = DesktopLook.Accent(t.ChosenRow, dark).Over(t.Grouped);
        Assert.NotEqual(t.Grouped, mark);
        Assert.True(t.Label.Over(mark).Contrast(mark) >= 4.5);
        Assert.Equal("WindowText", HighContrastWalkProof.SystemColourFor("HQSettingsPaneLineBrush"));
        Assert.Equal("Highlight", HighContrastWalkProof.SystemColourFor("HQSettingsMarkBrush"));
        Assert.Equal("Window", HighContrastWalkProof.SystemColourFor("HQSettingsFieldBrush"));
    }

    [Fact]
    public void SearchAndGatewayDoNotStealTheLastCategoryOrLeaveTwoMarks()
    {
        foreach (var c in SettingsCategories.All)
        {
            var kept = SettingsWindowPlan.OpeningCategory(c.Key());
            foreach (var (gateway, searching) in new[] { (false, true), (true, false), (true, true) })
                Assert.Equal(-1, SettingsColumnLayout.SelectedIndex(kept, gateway, searching));
            Assert.Equal(c, SettingsCategories.All[SettingsColumnLayout.SelectedIndex(kept, false, false)]);
        }
    }
}
