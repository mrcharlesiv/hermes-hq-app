using Hermes.Core.Artifacts;
using Hermes.Core.Shell;

namespace HermesHQ.Features.Artifacts;

internal sealed partial class ArtifactFileWindow
{
    private static readonly FileWindowRegistry<ArtifactFileWindow> Registry = new();

    internal static IReadOnlyList<string> OpenKeys => [.. Registry.Keys];
    internal static ArtifactFileWindow? Showing(string key) => Registry.Find(key);

    internal static int CloseAllForQuit() =>
        ShutdownPlan.CloseEach(Registry.Keys.Select(Registry.Find).OfType<ArtifactFileWindow>(), w => w.Close());
}