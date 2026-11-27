using Hermes.Core.BotPages;
using Hermes.Core.Bots;
using Hermes.Core.Shell;
using HermesHQ.Features.QuickActions;
using HermesHQ.Services;
using HermesHQ.Shell;
using Xunit;

namespace Hermes.Tests;

public class FavoritesPlaceTests
{
    [Fact]
    public void RegistrationAndLookupKeepOneStarredPlaceWithoutChangingSavedChoices()
    {
        const string id = "quick-actions";
        var disk = new MemoryDeviceStore();
        new SidebarLayout { Order = ["artifacts", id, "sessions"] }.Save(disk);
        var saved = disk.Read("sidebar");

        QuickActionsFeature.Register();
        QuickActionsFeature.Register();
        var place = Assert.Single(Places.All, p => p.Id == id);
        Assert.Equal(("Favorites", "\uE735", Places.Tools, typeof(QuickActionsPage)), (place.Title, place.Glyph, place.Section, place.Page));
        Assert.Single(ChatExtensions.OnOpen);
        Assert.DoesNotContain(Places.All, p => p.Id == "favorites");

        var infos = Places.All.Select(p => new PlaceInfo(p.Id, p.Title, p.Section == Places.Tools)).ToList();
        var defaults = new SidebarLayout();
        Assert.Equal(id, defaults.Tools(infos).First(p => p != PlaceKeys.Bots));
        var kept = SidebarLayout.Load(disk);
        Assert.Equal(["artifacts", id, "sessions"], kept.Shown(infos));
        Assert.DoesNotContain(id, kept.Tools(infos));
        var numbered = PlaceKeys.Numbered(kept.Shown(infos), kept.Tools(infos));
        Assert.Equal(3, PlaceKeys.Number(numbered.IndexOf(id), numbered.Count));
        Assert.Equal(saved, disk.Read("sidebar"));

        var pages = Places.All.Select(p => new MoreSearch.Item(p.Id, p.Title, Keywords: p.Keywords));
        foreach (var term in new[] { "Favorites", "Quick Actions", "favourites", "starred", "quick access" })
        {
            var group = Assert.Single(MoreSearch.Results(term, pages, [], [], [], []));
            Assert.Equal(MoreSearch.Kind.GoTo, group.Kind);
            var result = Assert.Single(group.Rows);
            Assert.Equal((id, "Favorites"), (result.Id, result.Title));
        }
        Assert.False(Directory.Exists(AppPaths.Root));  // fresh registration did not create a tile file
    }
}
