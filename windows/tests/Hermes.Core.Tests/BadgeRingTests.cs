// [WIN-ROW-FACE-RING-PANEL] A sidebar face's badges are ringed in the colour behind them, the sidebar's panel, not the
// page. As the Mac at 93f984bb1: App/Bots/BotRowViews.swift (every badge's `.background(Circle().fill(ring ??
// Color.hqPage).padding(-2))`, `EnvironmentValues.hqBadgeRing`), App/Mac/MacBotsRail.swift (`MacRailHead.configuration`
// sets it to `MacSidebar.panelColor`, for the open sidebar's rows and the folded rail alike) and App/Mac/MacSidebar.swift
// (`panelColor`: `Theme.isDesktop ? ChatPalette.sidebar : glassTintColor` made opaque; `glassTintColor`: the page 10 % of
// the way to its ink in light, 14 % in dark). Synthetic data only.
using System.Text.RegularExpressions;
using Hermes.Core.Bots;
using Hermes.Core.Settings;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

public class BadgeRingTests
{
    private static void Near(double expected255, double actual01) => Assert.InRange(actual01 * 255, expected255 - 0.01, expected255 + 0.01);

    private static void Same(Rgba expected, Rgba actual)
    {
        Near(expected.R * 255, actual.R); Near(expected.G * 255, actual.G); Near(expected.B * 255, actual.B);
        Assert.Equal(expected.A, actual.A, 6);
    }

    [Fact]
    public void TheStandardLooksPanelIsThePageAShadeTowardItsInk()
    {
        var set = ThemeResolver.Resolve(ThemeState.Default);
        // Light: #FEFEFE 10 % of the way to #1F2328.
        var light = set.Light.SidebarPanel;
        Near(254 + (31 - 254) * 0.10, light.R); Near(254 + (35 - 254) * 0.10, light.G); Near(254 + (40 - 254) * 0.10, light.B);
        Assert.Equal(1, light.A);
        // Dark: #0D1015 14 % of the way to #E6EDF3.
        var dark = set.Dark.SidebarPanel;
        Near(13 + (230 - 13) * 0.14, dark.R); Near(16 + (237 - 16) * 0.14, dark.G); Near(21 + (243 - 21) * 0.14, dark.B);
        Assert.Equal(1, dark.A);
        Assert.NotEqual(set.Light.Page, light);
        Assert.NotEqual(set.Dark.Page, dark);
    }

    [Fact]
    public void TheGlassTintReadsTheInksChannelsNotItsAlpha()
    {
        var tint = ThemeResolver.GlassTint(Rgba.White, Rgba.Black.Alpha(0.94), dark: false);
        Near(229.5, tint.R); Near(229.5, tint.G); Near(229.5, tint.B);
        Assert.Equal(0.85, tint.A, 6);
        var night = ThemeResolver.GlassTint(Rgba.Black, Rgba.White.Alpha(0.94), dark: true);
        Near(35.7, night.R);
        Assert.Equal(0.85, night.A, 6);
    }

    [Fact]
    public void TheDesktopLooksPanelIsItsSidebar()
    {
        var set = ThemeResolver.Resolve(ThemeState.Default with { DesktopLook = true });
        foreach (var t in new[] { set.Light, set.Dark })
            Same(t.Sidebar.Alpha(1), t.SidebarPanel);
        var contrast = ThemeResolver.Resolve(ThemeState.Default with { DesktopLook = true, HighContrast = true });
        Same(contrast.Dark.Sidebar.Alpha(1), contrast.Dark.SidebarPanel);
    }

    [Fact]
    public void EverySkinsPanelIsOpaqueAndFollowsTheLooksRule()
    {
        foreach (var skin in SkinCatalog.All)
        {
            foreach (var desktop in new[] { false, true })
            {
                var set = ThemeResolver.Resolve(ThemeState.Default with { SkinId = skin.Id, DesktopLook = desktop });
                foreach (var (t, wantsDark) in new[] { (set.Light, false), (set.Dark, true) })
                {
                    Assert.Equal(1, t.SidebarPanel.A);
                    if (desktop) Same(t.Sidebar.Alpha(1), t.SidebarPanel);
                    else
                    {
                        // The mode a palette is painted in: the default skin follows the window, a skin its own ground.
                        var dark = skin.Id == SkinCatalog.DefaultId ? wantsDark : skin.Seeds(wantsDark).RendersDark;
                        Same(ThemeResolver.GlassTint(t.Page, t.Label, dark).Alpha(1), t.SidebarPanel);
                    }
                }
            }
        }
    }

    [Fact]
    public void TheRingIsTwoWideInThePageByDefaultAndThePanelInTheSidebar()
    {
        Assert.Equal(2, BotList.BadgeRingWidth);
        var t = ThemeResolver.Resolve(ThemeState.Default).Light;
        Assert.Equal(t.Page, BotList.BadgeRing(BotList.BadgeGround.Page, t));
        Assert.Equal(t.SidebarPanel, BotList.BadgeRing(BotList.BadgeGround.SidebarPanel, t));
        Assert.Equal("HQPageBrush", BotList.BadgeRingBrushKey(BotList.BadgeGround.Page));
        Assert.Equal("HQSidebarPanelBrush", BotList.BadgeRingBrushKey(BotList.BadgeGround.SidebarPanel));
        // Under a Windows contrast theme the panel is a ground: Window, as the sidebar's.
        Assert.Equal("Window", HighContrastWalkProof.SystemColourFor("HQSidebarPanelBrush"));
    }

    // MARK: The Windows sidebar draws it

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", .. parts]));
    }

    private static string Body(string source, string signature) =>
        Regex.Match(source, Regex.Escape(signature) + @"(?<b>.*?)\n    \}", RegexOptions.Singleline).Groups["b"].Value;

    [Fact]
    public void TheSidebarsBadgesAreRingedInThePanelTwoWide()
    {
        var theme = Source("Features", "Settings", "ThemeService.cs");
        Assert.Contains("(\"HQSidebarPanelBrush\", t => t.SidebarPanel)", theme);
        var items = Source("Shell", "SidebarItems.cs");
        Assert.Contains("private static Brush Ring => Res(BotList.BadgeRingBrushKey(BotList.BadgeGround.SidebarPanel));", items);
        foreach (var signature in new[] { "private static Grid RingedDot(double dot, string fill)", "private static Grid RingedBadge(double badge, UIElement content)" })
        {
            var body = Body(items, signature);
            Assert.NotEmpty(body);
            Assert.Contains("g.Children.Add(new Ellipse { Fill = Ring });", body);
            Assert.Contains("const double ring = BotList.BadgeRingWidth;", body);
            Assert.DoesNotContain("SolidBackgroundFillColorBaseBrush", body);   // the page colour: a halo on the panel
        }
        // A dot sits 1 outside the face, a badge 2, each with its ring round it.
        Assert.Contains("Margin = new Thickness(0, 0, -(1 + ring), -(1 + ring))", Body(items, "private static Grid RingedDot(double dot, string fill)"));
        Assert.Contains("Margin = new Thickness(0, 0, -(2 + ring), -(2 + ring))", Body(items, "private static Grid RingedBadge(double badge, UIElement content)"));
        // Every bot face badge goes through the two ringed holders (the rail's tile and the open sidebar's row alike).
        foreach (var badge in new[] { "PresenceDot(double dot)", "WaitingBadge(double dot)" })
            Assert.Contains("RingedDot(", Body(items, "private static Grid " + badge));
        foreach (var badge in new[] { "WorkingBadge(double badge)", "AttentionBadge(double badge)", "WakingBadge(double badge)" })
            Assert.Contains("RingedBadge(", Body(items, "private static Grid " + badge));
    }
}
