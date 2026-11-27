namespace HermesHQ.Features.Attachments;

internal sealed partial class MediaViewerWindow
{
    private static MediaViewerWindow? _open;

    internal static void CloseOpen() => _open?.Close();

    public static void Show(IReadOnlyList<ViewerItem> items, int start)
    {
        if (items.Count == 0) return;
        _open?.Close();
        var window = new MediaViewerWindow(items, Math.Clamp(start, 0, items.Count - 1));
        _open = window;
        window.Closed += (_, _) => { if (_open == window) _open = null; };
        window.Activate();
    }
}