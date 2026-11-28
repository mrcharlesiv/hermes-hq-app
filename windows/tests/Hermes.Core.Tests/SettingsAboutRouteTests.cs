using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// SettingsNavigator.openRoot and SettingsRootView's category in Mac build 1240: compare page identities, not titles.
/// The WinUI pane itself is seen only on Windows.
public class SettingsAboutRouteTests
{
    [Theory]
    [InlineData("about", new[] { "category:about", "about" })]
    [InlineData("about:detailed-log", new[] { "category:about", "about" })]
    [InlineData("licenses", new[] { "category:about", "about", "licenses" })]
    public void AboutTargetsKeepTheCategoryIndexUnderTheDetail(string target, string[] pages)
    {
        Assert.Equal(pages, SettingsAboutRoute.Pages(target));
        Assert.Equal(SettingsCategory.About, SettingsSearch.Category(target));
    }

    [Theory]
    [InlineData("about")]
    [InlineData("about:detailed-log")]
    [InlineData("licenses")]
    public void IdenticalAboutTitlesNeverStandForTheSameScreenTwice(string target)
    {
        var pages = SettingsAboutRoute.Pages(target)!;
        var titles = pages.Select(SettingsAboutRoute.Title).ToList();
        Assert.Equal(new[] { "About", "About" }, titles.Take(2));
        Assert.Equal(pages.Count, pages.Distinct(StringComparer.Ordinal).Count());
        Assert.Equal(SettingsAboutRoute.CategoryKey(SettingsCategory.About), pages[0]);
        // Only the category is the root; Back on the version/logging page takes us *to* it.
        Assert.Null(SettingsAboutRoute.BackLabel(pages.Take(1).ToList()));
    }

    [Fact]
    public void LicensesBackVisitsAboutDetailThenAboutCategory()
    {
        var pages = SettingsAboutRoute.Pages("licenses")!.ToList();
        Assert.Equal("‹ About", SettingsAboutRoute.BackLabel(pages));
        pages.RemoveAt(pages.Count - 1);   // Back
        Assert.Equal("about", pages[^1]);
        Assert.Equal("‹ About", SettingsAboutRoute.BackLabel(pages));
        pages.RemoveAt(pages.Count - 1);
        Assert.Equal("category:about", Assert.Single(pages));
        Assert.Null(SettingsAboutRoute.BackLabel(pages));
    }

    // From the captured Mac stack: a section and its detail share a title, never a page identity.
    [Theory]
    [InlineData("verbose", "about:detailed-log", new[] { "about", "category:about" })]
    [InlineData("licence", "licenses", new[] { "licenses", "about", "category:about" })]
    public void ReturningFromTheActualSearchResultVisitsEachScreenInOrder(string query, string target, string[] backPath)
    {
        var hit = SettingsSearch.Results(query, SettingsSearch.Index).First();
        Assert.Equal(target, hit.Target);
        var pages = SettingsAboutRoute.Pages(hit.Target)!.ToList();
        Assert.Equal(backPath.Length, pages.Count);
        foreach (var key in backPath)
        {
            Assert.Equal(key, pages[^1]);
            Assert.Equal(key == "category:about" ? null : "‹ About", SettingsAboutRoute.BackLabel(pages));
            pages.RemoveAt(pages.Count - 1);
        }
        Assert.Empty(pages);
    }

    [Theory]
    [InlineData("about:detailed-log", "about.detailed-log")]
    [InlineData("about", null)]
    [InlineData("licenses", null)]
    public void OnlyTheRowTargetRevealsARow(string target, string? row) => Assert.Equal(row, SettingsAboutRoute.Reveal(target));

    [Theory]
    [InlineData("theme")]
    [InlineData("diagnostics")]
    [InlineData("gateway")]
    [InlineData("row:ui-scale")]
    [InlineData("action:export")]
    [InlineData("action:reset")]
    public void OtherTargetsKeepTheirOwnRoutes(string target) => Assert.Null(SettingsAboutRoute.Pages(target));

    [Fact]
    public void FileActionsStillGoToTheAboutCategorysOwnPage()
    {
        // Export / Import / Reset moved to the Hermes (Gateway) category under Backup & Reset (e27566897).
        Assert.Equal(SettingsCategory.Gateway, SettingsSearch.Category("action:import"));
        Assert.Equal("About", SettingsAboutRoute.Title(SettingsAboutRoute.CategoryKey(SettingsCategory.About)));
    }

    [Fact]
    public void SettingsPageOpenBuildsAboutsPagesFromTheRoute()
    {
        var src = File.ReadAllText(Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows", "Features", "Settings", "SettingsPage.cs"));
        var open = src[src.IndexOf("public void Open(string target", StringComparison.Ordinal)..];
        Assert.Contains("SettingsAboutRoute.Pages(target)", open);
        Assert.Contains("SettingsAboutRoute.Reveal(target)", open);
        // The first screen must render the category, not a second instance of the version/logging detail.
        Assert.Contains("key == SettingsAboutRoute.CategoryKey(category)", open);
        Assert.Contains("() => SettingsPanes.Category(this, category)", open);
        Assert.Contains("SettingsPanes.PageFor(this, key)", open);
        // A targeted route replaces the old stack (including a nested page or the gateway card).
        Assert.True(open.IndexOf("SettingsAboutRoute.Pages(target)", StringComparison.Ordinal)
            < open.IndexOf("SettingsSearch.Category(target)", StringComparison.Ordinal));
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "windows", "src"))) dir = dir.Parent;
        return dir?.FullName ?? throw new DirectoryNotFoundException("repo root");
    }
}
