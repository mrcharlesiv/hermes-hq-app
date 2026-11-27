using System.Globalization;
using System.Xml.Linq;
using Hermes.Core.Onboarding;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// Source layout and portable metrics, not a WinUI renderer. Widths are the scroll viewport's, not screen pixels.
public class WelcomeLayoutTests
{
    private static readonly XNamespace X = "http://schemas.microsoft.com/winfx/2006/xaml";
    private static XElement View()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "HermesHQ.sln"))) dir = dir.Parent;
        return XElement.Load(Path.Combine(dir!.FullName, "src", "HermesHQ.Windows", "Features", "Onboarding", "WelcomeScreen.xaml"));
    }
    private static XElement Named(XElement root, string name) => root.Descendants().Single(e => (string?)e.Attribute(X + "Name") == name);
    private static double Number(XElement e, string key) => double.Parse((string)e.Attribute(key)!, CultureInfo.InvariantCulture);
    private static double Top(XElement e) => double.Parse(((string)e.Attribute("Margin")!).Split(',')[1], CultureInfo.InvariantCulture);

    [Theory]
    [InlineData(1028, 338.8)]
    [InlineData(375.76, 338.8)] // cap plus both gutters
    [InlineData(320, 283.04)]
    [InlineData(240, 203.04)]
    public void GuttersAreOutsideTheCapAndBothButtonsUseTheWholeWordsColumn(double viewport, double expected)
    {
        var page = View();
        var room = Named(page, "Room");
        var column = Named(page, "Column");
        Assert.Same(room, column.Parent);
        Assert.Null(column.Attribute("Width"));
        Assert.Null(column.Attribute("Padding"));
        Assert.Equal(expected, Math.Min(Number(column, "MaxWidth"), viewport - 2 * Number(room, "Padding")), 4);
        var actions = Named(page, "Actions");
        Assert.Same(column, actions.Parent);
        Assert.Same(Named(page, "Points"), actions.ElementsBeforeSelf().Last());
        Assert.Equal(new[] { "Start", "Address" }, actions.Elements().Select(e => (string)e.Attribute(X + "Name")!));
        Assert.All(actions.Elements(), b =>
        {
            Assert.Equal("Button", b.Name.LocalName);
            Assert.Equal("Stretch", (string?)b.Attribute("HorizontalAlignment"));
            Assert.Null(b.Attribute("Width"));
            Assert.Null(b.Attribute("Height"));
        });
    }

    [Fact]
    public void FittingBlockCentresBelowTheBarButATallBlockCanScrollFromItsTopThroughBothActions()
    {
        var page = View();
        var viewport = Named(page, "Viewport");
        var room = Named(page, "Room");
        var column = Named(page, "Column");
        Assert.Equal("ScrollViewer", viewport.Name.LocalName);
        Assert.Equal("Disabled", (string?)viewport.Attribute("HorizontalScrollBarVisibility"));
        Assert.Equal("Auto", (string?)viewport.Attribute("VerticalScrollBarVisibility"));
        Assert.Same(viewport, room.Parent);
        Assert.Equal("ViewportChanged", (string?)viewport.Attribute("SizeChanged")); // maintain the minimum on each resize
        Assert.Equal("Center", (string?)column.Attribute("VerticalAlignment"));
        Assert.Null(room.Attribute("Height"));
        Assert.Null(column.Attribute("Height"));
        Assert.All(page.Descendants().Where(e => e.Name.LocalName == "TextBlock"), text =>
        {
            Assert.Equal("Wrap", (string?)text.Attribute("TextWrapping"));
            Assert.Null(text.Attribute("MaxLines"));
            Assert.Null(text.Attribute("Height"));
        });
        Assert.Equal("{ThemeResource HQPageBrush}", (string?)Named(page, "PageGround").Attribute("Background"));
    }

    [Fact]
    public void OrdinaryBlockProjectsTheMacIconAndBothActionsWithoutFixedPositions()
    {
        // Oracle: the original 1028 × 779 Mac pair, two heading lines, three lead lines, one per point label.
        // These observed pixels are not layout inputs. This projects unrounded boxes; it isn't a WinUI font shaper.
        var page = View();
        var column = Named(page, "Column");
        var icon = Named(page, "AppMark");
        var points = Named(page, "Points");
        var actions = Named(page, "Actions");
        var bar = page.Descendants().Single(e => (string?)e.Attribute(X + "Key") == "WelcomeGuideBar");
        double nav = Number(bar.Elements().Single(e => (string?)e.Attribute("Property") == "MinHeight"), "Value");
        var m = WelcomeMetrics.For(1, desktop: false);
        double beforeActions = Number(icon, "Height") + Top(Named(page, "Heading")) + 2 * m.TitleLine.Pitch + m.TitleLine.EndMargin
            + Top(Named(page, "Lead")) + 3 * m.LeadLine.Pitch + m.LeadLine.EndMargin + Top(points)
            + OnboardingCopy.Welcome.Points.Length * (m.HeadlineLine + WelcomeMetrics.PointTextGap + m.DetailLine)
            + (OnboardingCopy.Welcome.Points.Length - 1) * Number(points, "Spacing") + Top(actions);
        double actionGap = Number(actions, "Spacing"), width = Number(column, "MaxWidth");
        double height = beforeActions + 2 * m.ButtonMinHeight + actionGap;
        double iconY = (779 + 40 + nav - height) / 2; // unchanged 40-DIP Windows caption, MainWindow.xaml
        double primaryY = iconY + beforeActions, secondaryY = primaryY + m.ButtonMinHeight + actionGap;
        static void Near(double expected, double actual) => Assert.InRange(actual, expected - 1, expected + 1);
        Near(195, iconY); Near(345, (1028 - width) / 2); Near(339, width);
        Near(584, primaryY); Near(33, m.ButtonMinHeight); Near(626, secondaryY); Near(658, secondaryY + m.ButtonMinHeight);
        Assert.Equal(55.44, Number(icon, "Width"), 3);
        Assert.Equal(Number(icon, "Height"), Number(icon, "Width"));
        Assert.Equal(Number(icon, "Width") * 0.2237, Number(icon, "CornerRadius"), 3);
        Assert.Equal(new[] { "AppMark", "Heading", "Lead", "Points", "Actions" }, column.Elements().Select(e => (string?)e.Attribute(X + "Name")));
    }

    [Theory]
    [InlineData(1, 23.1, 32.34)]
    [InlineData(1.5, 34.65, 45.43)]
    [InlineData(2.25, 40.04, 65.065)] // cap on the symbol track, not the button or its wrapped text
    public void LargerWindowsTextGrowsTheTrackAndMinimumHitAreaWithoutScalingFontsTwice(double scale, double track, double button)
    {
        var m = WelcomeMetrics.For(scale, desktop: false);
        Assert.Equal(track, m.SymbolTrack, 4);
        Assert.Equal(button, m.ButtonMinHeight, 4);
        Assert.Equal(30.03, m.Title, 4);
        Assert.Equal(15.015, m.Body, 4);
        Assert.Equal(13.475, m.Detail, 4);
        Assert.Equal(17.71, m.Symbol, 4);
        Assert.Equal(scale == 1 ? 36.19 : 0, m.TitleLine.Pitch, 4);
        Assert.Equal(scale == 1 ? 20.02 : 0, m.LeadLine.Pitch, 4);
        Assert.Equal(scale == 1 ? -0.77 : 0, m.TitleLine.EndMargin, 4);
        Assert.Equal(scale == 1 ? -1.54 : 0, m.LeadLine.EndMargin, 4);
        Assert.Equal(scale == 1 ? 18.48 : 0, m.HeadlineLine, 4);
        Assert.Equal(scale == 1 ? 16.17 : 0, m.DetailLine, 4);
    }

    [Theory]
    // Detached 1245 HQFont at the ordinary OS text size, in screen points (no Windows rasterization).
    [InlineData(80, true, 17.71, 11.935, 11.55, 12.705, 5.775)]  // desktop floor on the detail face
    [InlineData(86, false, 25.795, 13.09, 11.55, 15.4, 11.55)]
    [InlineData(90, false, 26.95, 13.475, 11.935, 15.785, 11.55)]
    [InlineData(110, false, 33.11, 16.555, 14.63, 19.635, 13.09)]
    [InlineData(125, false, 37.73, 18.865, 16.555, 22.33, 14.63)]
    [InlineData(137, true, 30.03, 20.405, 18.48, 21.945, 5.775)]
    [InlineData(150, false, 45.045, 22.715, 20.02, 26.565, 16.94)]
    [InlineData(160, false, 48.125, 24.255, 21.175, 28.49, 17.71)]
    public void AppPercentageSizesTypeButDoesNotScaleTheDynamicTypeTrackOrButtonMinimum(int percent, bool desktop,
        double title, double body, double detail, double symbol, double corner)
    {
        var m = WelcomeMetrics.For(1, desktop, percent);
        Assert.Equal(title, m.Title, 4); Assert.Equal(body, m.Body, 4);
        Assert.Equal(detail, m.Detail, 4); Assert.Equal(symbol, m.Symbol, 4);
        Assert.Equal(corner, m.ButtonCorner, 4);
        Assert.Equal(23.1, m.SymbolTrack, 4); Assert.Equal(32.34, m.ButtonMinHeight, 4);
        Assert.Equal(default, m.TitleLine); Assert.Equal(default, m.LeadLine);
        Assert.Equal(0, m.HeadlineLine); Assert.Equal(0, m.DetailLine);

        // WinUI enlarges the faces itself. Only the ScaledMetric geometry consumes the OS factor here.
        var larger = WelcomeMetrics.For(2.25, desktop, percent);
        Assert.Equal((m.Title, m.Body, m.Detail, m.Symbol), (larger.Title, larger.Body, larger.Detail, larger.Symbol));
        Assert.Equal(40.04, larger.SymbolTrack, 4); Assert.Equal(65.065, larger.ButtonMinHeight, 4);
    }

    [Fact]
    public void DesktopLookHasItsOwnTitleAndKeepsLineSpacingBetweenLinesOnly()
    {
        var m = WelcomeMetrics.For(1, desktop: true);
        Assert.Equal(21.945, m.Title, 4);
        Assert.Equal(52.36, 2 * m.TitleLine.Pitch + m.TitleLine.EndMargin, 4);
        Assert.Equal(60.06, 3 * m.LeadLine.Pitch + m.LeadLine.EndMargin, 4);
        Assert.Equal(5.775, m.ButtonCorner, 4);
    }

    [Fact]
    public void ArtworkIsTheHiddenRoundedFillAndContrastKeepsTheNativeButtons()
    {
        var page = View();
        var icon = Named(page, "AppMark");
        Assert.Equal("Border", icon.Name.LocalName);
        Assert.Equal("Raw", (string?)icon.Attribute("AutomationProperties.AccessibilityView"));
        Assert.Equal("{ThemeResource WelcomeMark}", (string?)icon.Attribute("Background"));
        var themes = page.Descendants().Single(e => e.Name.LocalName == "ResourceDictionary.ThemeDictionaries");
        foreach (string theme in new[] { "Light", "Dark", "HighContrast" })
        {
            var dictionary = themes.Elements().Single(e => (string?)e.Attribute(X + "Key") == theme);
            var mark = Assert.Single(dictionary.Elements());
            Assert.Equal("ImageBrush", mark.Name.LocalName);
            Assert.Equal("WelcomeMark", (string?)mark.Attribute(X + "Key"));
            Assert.Equal(theme == "Dark" ? "ms-appx:///Assets/Onboarding/Welcome-dark.png" : "ms-appx:///Assets/HermesHQ-256.png", (string?)mark.Attribute("ImageSource"));
        }
        Assert.Equal("Level1", (string?)Named(page, "Heading").Attribute("AutomationProperties.HeadingLevel"));
        Assert.Equal("False", (string?)page.Attribute("IsTabStop"));
        Assert.All(Named(page, "Actions").Elements(), b => Assert.Null(b.Attribute("IsTabStop"))); // native button default
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    public void ActualButtonKeysUseTheAppTintAndTheModesPlainFace(bool dark, bool desktop)
    {
        var page = View();
        var t = ThemeResolver.Resolve(ThemeState.Default with { DesktopLook = desktop }).Tokens(dark);
        var brushes = new Dictionary<string, Rgba>();
        WelcomeMetrics.ButtonBrushes(t, dark, desktop, brushes.Add);
        Rgba Bound(string name, string property)
        {
            var key = (string)Named(page, name).Attribute(property)!;
            const string prefix = "{ThemeResource ";
            Assert.StartsWith(prefix, key);
            Assert.EndsWith("}", key);
            return brushes[key[prefix.Length..^1]];
        }
        Assert.Equal(t.Tint, Bound("Start", "Background"));
        Assert.Equal(t.OnTint, Bound("Start", "Foreground"));
        Assert.Equal(t.Tint, Bound("Start", "BorderBrush"));
        Assert.Equal(!dark && !desktop ? t.GroupedCard : t.Fill3, Bound("Address", "Background"));
        Assert.Equal(t.Label, Bound("Address", "Foreground"));
        Assert.Equal(t.Label3.Alpha(desktop ? 0.55 : 0.28), Bound("Address", "BorderBrush"));
        foreach (var suffix in new[] { "PointerOver", "Pressed" })
        {
            Assert.NotEqual(t.Tint, brushes["AccentButtonBackground" + suffix]);
            Assert.Equal(t.OnTint, brushes["AccentButtonForeground" + suffix]);
            Assert.Equal(t.Label, brushes["ButtonForeground" + suffix]);
        }
        Assert.DoesNotContain(brushes.Keys, k => k.Contains("Disabled") || k.Contains("Focus"));
    }
}
