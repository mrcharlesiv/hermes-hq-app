using Hermes.Core.Insights;
using Xunit;

namespace Hermes.Core.Tests.Insights;

public class StarMapAndSpawnTreeRulesTests
{
    [Theory]
    [InlineData(null, false, false)]
    [InlineData("map", false, false)]
    [InlineData("list", false, true)]
    [InlineData("LIST", false, true)]
    [InlineData(null, true, true)]
    [InlineData("map", true, true)]
    [InlineData("list", true, true)]
    public void StarMapInitialListModeHonorsScreenReaderWithoutOverwritingSavedMapPref(
        string? savedPref, bool screenReaderActive, bool expectedList)
    {
        Assert.Equal(expectedList, StarMapViewRules.InitialListMode(savedPref, screenReaderActive));
    }

    [Fact]
    public void StarMapDesktopFitScaleCapsInitialZoomToMatchMacCatalystProportions()
    {
        Assert.Equal(0.77, StarMapViewRules.DesktopFitScale, 6);
        var graph = new StarMapGraph(
            nodes:
            [
                new StarMapNode("s1", "Deploy", StarMapKind.Skill, "deploys", UseCount: 10),
                new StarMapNode("s2", "Rollback", StarMapKind.Skill, "deploys", UseCount: 4),
                new StarMapNode("m1", "Prefs", StarMapKind.Memory, "memory", UseCount: 5),
            ],
            edges: [new StarMapEdge("s1", "s2")]);
        var layout = StarMapShown.Make(graph, StarMapFilter.All, 1).Layout;
        var defaultCam = layout.Whole(767, 600);
        var desktopCam = layout.Whole(767, 600, most: StarMapViewRules.DesktopFitScale);

        Assert.True(desktopCam.Scale <= StarMapViewRules.DesktopFitScale + 1e-9);
        Assert.True(desktopCam.Scale <= defaultCam.Scale);
    }

    [Theory]
    [InlineData(600, false)]
    [InlineData(740, false)]
    [InlineData(741.76, false)]
    [InlineData(741.99, false)]
    [InlineData(742.0, true)]
    [InlineData(766.38, true)]
    [InlineData(1000, true)]
    [InlineData(double.NaN, false)]
    [InlineData(double.PositiveInfinity, false)]
    public void SpawnTreeBreakpointMatchesMacWideThreshold(double width, bool expectedWide)
    {
        Assert.Equal(742, SpawnTree.WideAt);
        Assert.Equal(expectedWide, SpawnTree.IsWide(width));
    }
}
