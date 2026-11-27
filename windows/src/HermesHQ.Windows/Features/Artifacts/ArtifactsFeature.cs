using HermesHQ.Services;
using HermesHQ.Shell;

namespace HermesHQ.Features.Artifacts;

/// Artifacts (PARITY.md, Pages): the sidebar's Artifacts place. Its store, index and pictures belong to the gateway in
/// use, so a switch or sign-out starts the next page from that account's own.
public static class ArtifactsFeature
{
    public static void Register()
    {
        Places.Register("artifacts", typeof(ArtifactsPage));
        AppState.ClientChanged += _ => ArtifactsHub.Reset();
        // [mac-files] [mac-pages] Files, pages and notes opened from a chat, a tile or a bot's files: a window of their own.
        FileWindows.Open = ArtifactFileWindow.OpenRouted;
    }
}
