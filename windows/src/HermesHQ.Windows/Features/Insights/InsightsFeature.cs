using HermesHQ.Shell;

namespace HermesHQ.Features.Insights;

/// The Insights pages (PARITY.md Pages: Status & Maintenance, Usage, Spawn Tree, Star Map, Tiles). The Mac's More
/// rows (App/Pages/More/Kit/MorePages.swift) are sidebar Tools there, as here.
public static class InsightsFeature
{
    public static void Register()
    {
        Places.Register("command-center", typeof(CommandCenterPage));
        Places.Register("usage", typeof(UsagePage));
        Places.Register("spawn-tree", typeof(SpawnTreePage));
        Places.Register("star-map", typeof(StarMapPage));
        Places.Register("tiles", typeof(TilesPage));
        // The "too old" page after a sign-in runs the update from the app, as the Mac's does.
        Gateways.UpdateHermesView.UpdateHook = (root, afterUpdated) =>
        {
            if (Services.AppState.Client is { } client) UpdateSheet.Update(client, root, afterUpdated);
        };
    }
}
