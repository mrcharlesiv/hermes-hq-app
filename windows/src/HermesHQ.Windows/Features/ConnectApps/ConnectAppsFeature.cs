using Hermes.Core.Composio;
using HermesHQ.Services;
using HermesHQ.Shell;

namespace HermesHQ.Features.ConnectApps;

/// Connect Apps (Composio) feature registration: claims `"connect-apps"` place and manages the background All Bots reconciler
/// (`App/ConnectApps/ComposioModel.swift`).
public static class ConnectAppsFeature
{
    public const string PlaceId = "connect-apps";

    private static bool _registered;

    internal static IComposioKeyStore KeyStore { get; } =
        Automation.AppOnly || Automation.Enabled ? new MemoryComposioKeyStore() : new ComposioKeyStore();

    /// Registers `"connect-apps"` -> `ConnectAppsPage` and hooks gateway lifecycle for `ComposioReconciler`.
    public static void Register()
    {
        if (_registered) return;
        _registered = true;

        if (Places.All.All(p => p.Id != PlaceId))
        {
            Places.All.Add(new Place(PlaceId, "Connect Apps", "\uE703", Places.Tools, typeof(ConnectAppsPage),
                ["composio", "connect", "apps", "gmail", "calendar", "slack", "github", "notion", "oauth"]));
        }
        Places.Register(PlaceId, typeof(ConnectAppsPage));

        AppState.ClientChanged += ComposioReconciler.Shared.Start;
        if (AppState.Client is { } client) ComposioReconciler.Shared.Start(client);
    }

    public static void Open()
    {
        Register();
        Navigator.Open(PlaceId);
    }
}
