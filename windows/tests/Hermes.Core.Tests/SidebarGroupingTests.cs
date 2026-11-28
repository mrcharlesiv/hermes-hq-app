using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

public class SidebarGroupingTests
{
    [Fact]
    public void ToolsExcludesSettingsPlace()
    {
        var all = new List<PlaceInfo>
        {
            new("sessions", "Sessions", false),
            new("tasks", "Tasks", true),
            new("settings", "Settings", true),
        };
        var layout = new SidebarLayout();
        Assert.Equal(["tasks"], layout.Tools(all));
    }

    [Fact]
    public void PartitionGroupsToolsIntoCategoriesAndPreservesUnknowns()
    {
        var tools = new List<string>
        {
            "quick-actions", "tasks", "files", "terminal", "usage", "marketplace", "profiles", "custom-tool",
        };
        var groups = SidebarToolGroups.Partition(tools);
        Assert.Equal(["Productivity", "Workspace", "Monitor", "Integrations", "More Tools"], groups.Select(g => g.Title));
        Assert.Equal(["quick-actions", "tasks"], groups[0].PlaceIds);
        Assert.Equal(["files", "terminal"], groups[1].PlaceIds);
        Assert.Equal(["usage"], groups[2].PlaceIds);
        Assert.Equal(["marketplace", "profiles"], groups[3].PlaceIds);
        Assert.Equal(["custom-tool"], groups[4].PlaceIds);
    }

    [Fact]
    public void PartitionOmitsEmptyCategories()
    {
        var groups = SidebarToolGroups.Partition(["tasks", "files"]);
        Assert.Equal(["Productivity", "Workspace"], groups.Select(g => g.Title));
    }

    [Fact]
    public void IsToolsHeaderKeyMatchesLegacyAndGroupedKeys()
    {
        Assert.True(SidebarToolGroups.IsToolsHeaderKey("tools"));
        Assert.True(SidebarToolGroups.IsToolsHeaderKey("tools:work"));
        Assert.True(SidebarToolGroups.IsToolsHeaderKey("tools:setup"));
        Assert.False(SidebarToolGroups.IsToolsHeaderKey("pinned"));
    }
}
