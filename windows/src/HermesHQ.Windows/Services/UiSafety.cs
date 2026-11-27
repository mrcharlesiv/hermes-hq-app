using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Services;

/// Safe wrappers around Windows clipboard, ContentDialog, visual-tree teardown, and shared WebView2 environment.
internal static class SafeClipboard
{
    public static bool TrySetText(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        return TrySetContent(package);
    }

    public static bool TrySetContent(DataPackage package)
    {
        try
        {
            Clipboard.SetContent(package);
            Clipboard.Flush();
            return true;
        }
        catch (Exception e)
        {
            AppLog.Note("clipboard", $"set failed: {e.GetType().Name}");
            return false;
        }
    }

    public static DataPackageView? TryGetContent()
    {
        try { return Clipboard.GetContent(); }
        catch (Exception e)
        {
            AppLog.Note("clipboard", $"read failed: {e.GetType().Name}");
            return null;
        }
    }

    public static bool TryContains(string formatId)
    {
        try { return Clipboard.GetContent().Contains(formatId); }
        catch (Exception e)
        {
            AppLog.Note("clipboard", $"contains failed: {e.GetType().Name}");
            return false;
        }
    }
}

internal static class SafeDialog
{
    /// Shows a ContentDialog only when XamlRoot is live, catching WinUI's single-dialog-at-a-time COMException.
    public static async Task<ContentDialogResult> ShowAsync(XamlRoot? root, ContentDialog dialog)
    {
        if (root == null || AppShutdown.Stopping) return ContentDialogResult.None;
        dialog.XamlRoot = root;
        try { return await dialog.ShowAsync(); }
        catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException or ArgumentException)
        {
            AppLog.Note("dialog", $"show skipped: {e.GetType().Name}");
            return ContentDialogResult.None;
        }
    }
}

internal static class UiTree
{
    /// Removes an element from whichever logical or visual parent currently holds it, avoiding WinUI reparent COMExceptions.
    public static void DetachFromParent(FrameworkElement element)
    {
        Detach(element, element.Parent);
        Detach(element, VisualTreeHelper.GetParent(element));
    }

    private static void Detach(FrameworkElement element, DependencyObject? parent)
    {
        switch (parent)
        {
            case Panel panel:
                panel.Children.Remove(element);
                break;
            case Border border when ReferenceEquals(border.Child, element):
                border.Child = null;
                break;
            case ContentControl content when ReferenceEquals(content.Content, element):
                content.Content = null;
                break;
            case ContentPresenter presenter when ReferenceEquals(presenter.Content, element):
                presenter.Content = null;
                break;
        }
    }

    /// Stops every active ProgressRing under `root` before tearing down or replacing its container.
    /// Active WinUI ProgressRings run Lottie animations that can fault during removal or shutdown.
    public static void DeactivateProgressRings(DependencyObject? root)
    {
        if (root == null) return;
        if (root is ProgressRing ring)
        {
            ring.IsActive = false;
            return;
        }
        var visualCount = VisualTreeHelper.GetChildrenCount(root);
        if (visualCount > 0)
        {
            for (var i = 0; i < visualCount; i++)
                DeactivateProgressRings(VisualTreeHelper.GetChild(root, i));
            return;
        }
        switch (root)
        {
            case Panel panel:
                foreach (var child in panel.Children) DeactivateProgressRings(child);
                break;
            case Border { Child: { } child }:
                DeactivateProgressRings(child);
                break;
            case ContentControl { Content: DependencyObject content }:
                DeactivateProgressRings(content);
                break;
        }
    }

    /// Stops any active ProgressRings in `panel` and clears its children.
    public static void ClearPanel(Panel panel)
    {
        DeactivateProgressRings(panel);
        panel.Children.Clear();
    }
}

internal static class WebViewEnv
{
    private static Task<CoreWebView2Environment>? _environment;

    /// Shared WebView2 environment in the app's writable data folder (never caches a faulted or canceled Task).
    public static async Task<CoreWebView2Environment> GetAsync()
    {
        var task = _environment;
        if (task == null || task.IsFaulted || task.IsCanceled)
        {
            task = CoreWebView2Environment.CreateWithOptionsAsync(
                null, Path.Combine(AppPaths.Root, "webview2"), null).AsTask();
            _environment = task;
        }
        try { return await task; }
        catch
        {
            if (ReferenceEquals(_environment, task)) _environment = null;
            throw;
        }
    }
}
