using System.Text.RegularExpressions;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// [density] The rest of Theme › Density on the lists Windows draws (Mac 93f984bb1): the Sessions page's project rows
/// (App/Sessions/ProjectCard.swift `face`, `rowPad`, `columnGap`, the header's `nameFont`) and its group captions
/// (SessionRowViews.swift `breakAbove`), and the one-line descriptions of Capabilities' and the Marketplace's rows
/// (ToolsetsSections, PluginsSections, HubSkillsSection, PluginCatalogPages `PluginCatalogRow`, Marketplace
/// `SkillCatalogRow`: `Density.compact ? 1 : 2`). Synthetic values only.
public class DensityRestTests
{
    [Fact]
    public void ProjectRowsKeepTheirStandardSizesAndTakeTheMacsCompactSteps()
    {
        Assert.Equal(new DensitySizes.ProjectSizes(Pad: 6, Folder: 16, Name: 15, Gap: 10), DensitySizes.Project(compact: false));
        // Row 36 → 32 (rowPad 4 + face 28 + 4 at Standard on the Mac, 5 + 22 + 5 in Compact), folder 28 → 22, name body
        // 17 → callout 16, column gap 12 → 10; each Windows size × Compact ÷ Standard, to the half point.
        Assert.Equal(new DensitySizes.ProjectSizes(Pad: 5.5, Folder: 12.5, Name: 14, Gap: 8.5), DensitySizes.Project(compact: true));
    }

    [Fact]
    public void GroupCaptionsStandCloserUnderCompact()
    {
        // breakAbove: 20 over a caption at Standard, 12 in Compact; Windows' 10 → 6.
        Assert.Equal(10, DensitySizes.HeaderAbove(compact: false));
        Assert.Equal(6, DensitySizes.HeaderAbove(compact: true));
    }

    [Fact]
    public void DescriptionsAreOneLineInCompact()
    {
        Assert.Equal(2, DensitySizes.DescriptionLines(compact: false));
        Assert.Equal(1, DensitySizes.DescriptionLines(compact: true));
        // The Desktop Look keeps its own rows: Compact there draws as Standard.
        var desk = ThemeState.Default with { Density = ListDensity.Compact, DesktopLook = true };
        Assert.Equal(2, DensitySizes.DescriptionLines(desk.Compact));
    }

    // ---------------------------------------------------------------- source (WinUI can't run here)

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", .. parts])).Replace("\r\n", "\n");
    }

    private static string Body(string source, string signature) =>
        Regex.Match(source, Regex.Escape(signature) + @"(?<b>.*?)\n    \}", RegexOptions.Singleline).Groups["b"].Value;

    [Fact]
    public void SessionsProjectAndHeaderRowsDrawAtTheDensity()
    {
        var sessions = Source("Pages", "SessionsPage.xaml.cs");
        var header = Body(sessions, "private static UIElement HeaderView(SessionGroup g)");
        Assert.Contains("DensitySizes.HeaderAbove(ThemeService.State.Compact)", header);
        var project = Body(sessions, "private static UIElement ProjectView(SessionGroup g, SessionStore store)");
        Assert.Contains("DensitySizes.Project(ThemeService.State.Compact)", project);
        foreach (var use in new[] { "ColumnSpacing = z.Gap", "z.Pad", "FontSize = z.Folder", "FontSize = z.Name" })
            Assert.Contains(use, project);
        // The page already draws again on DensitySizes.Changed (OnDensity → Rebuild).
        Assert.Contains("private void OnDensity() => Rebuild();", sessions);
    }

    [Fact]
    public void CapabilitiesDescriptionsTakeTheDensityAndRedrawWhenItChanges()
    {
        var list = Source("Features", "Capabilities", "ListScreen.cs");
        var market = Source("Features", "Capabilities", "MarketplaceScreen.cs");
        const string lines = "DensitySizes.DescriptionLines(ThemeService.State.Compact)";
        // Hub skills, toolsets and plugins: their description line.
        Assert.Contains($"Kit.Text(h.Description, 12, secondary: true).Also(t => t.MaxLines = {lines})", list);
        Assert.Contains($"Kit.Text(t.Description, 12, secondary: true).Also(x => x.MaxLines = {lines})", list);
        Assert.Contains($"Kit.Text(p.Description, 12, secondary: true).Also(t => t.MaxLines = {lines})", list);
        // Find Plugins' catalog rows (PluginCatalogRow) and the Marketplace's skill rows (SkillCatalogRow).
        Assert.Contains($"subtitleLines: {lines}", Body(list, "public static UIElement PluginCatalogRow(CapabilitiesModel m, PluginCatalogEntry e, Screen from)"));
        Assert.Contains($"subtitleLines: {lines}", Body(market, "private UIElement SkillRow(MarketSkill s)"));
        // The Marketplace grid's cards (PluginCatalogRow / SkillCatalogRow with no chevron).
        Assert.Contains($"Kit.Text(summary, 12, secondary: true).Also(t => t.MaxLines = {lines})", market);
        var kit = Source("Features", "Capabilities", "Kit.cs");
        Assert.Contains("int subtitleLines = 2", kit);
        Assert.Contains("sub.MaxLines = subtitleLines;", kit);
        var host = Source("Features", "Capabilities", "StackHost.cs");
        Assert.Contains("DensitySizes.Changed += OnDensity", host);
        Assert.Contains("DensitySizes.Changed -= OnDensity", host);
        Assert.Contains("private void OnDensity()", host);
    }
}
