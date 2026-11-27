using System.Text.RegularExpressions;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-PAGE-ZOOM] Source-level proof of the WinUI wiring (a WinUI page can't run here; the Windows runtime check is
/// separate): the HTML view, the file pane's bar and the page's own window use the one shared level, the page is drawn
/// at native size, no page script is added for zoom and the navigation guard is untouched.
public class PageZoomSourceTests
{
    private static string Windows(string relative)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", relative));
    }

    private static string HtmlView()
    {
        var all = Windows("Features/Artifacts/ArtifactViewers.cs");
        var start = all.IndexOf("internal sealed class ArtifactHtmlView", StringComparison.Ordinal);
        var end = all.IndexOf("internal sealed class PdfPagesView", StringComparison.Ordinal);
        Assert.True(start > 0 && end > start);
        return all[start..end];
    }

    [Fact]
    public void TheHtmlViewFollowsTheSharedLevelWhileOnScreenOnly()
    {
        var view = HtmlView();
        Assert.Contains("PageZoomShared.Level.Watch(", view);
        Assert.Contains("_zoomWatch?.Dispose()", view);
        // Watching starts on Loaded and stops on Unloaded and Close: a stale or closed preview isn't told.
        var unloaded = view[view.IndexOf("Unloaded +=", StringComparison.Ordinal)..view.IndexOf("public void Close()", StringComparison.Ordinal)];
        Assert.Contains("StopZoomWatch()", unloaded);
        var close = view[view.IndexOf("public void Close()", StringComparison.Ordinal)..];
        Assert.Contains("StopZoomWatch()", close[..close.IndexOf("public async Task<string?> PageTextAsync", StringComparison.Ordinal)]);
    }

    [Fact]
    public void ThePageIsLaidOutOverTheZoomAndDrawnGrownAtNativeSize()
    {
        var view = HtmlView();
        Assert.Contains("PageZoomSteps.Place(", view);
        Assert.Contains("new ScaleTransform", view);
        Assert.DoesNotMatch(new Regex(@"0\.77|Catalyst|/\s*0\.7"), view);
        var helper = File.ReadAllText(Path.Combine(CoreDir(), "Artifacts", "PageZoom.cs"));
        Assert.DoesNotMatch(new Regex(@"0\.77|77\s*%"), Regex.Replace(helper, @"//.*", ""));
    }

    [Fact]
    public void NoPageScriptIsAddedAndTheGuardIsUntouched()
    {
        var view = HtmlView();
        // The one script is the walk's read of the page's words (PageTextAsync), unchanged.
        Assert.Single(Regex.Matches(view, "ExecuteScriptAsync"));
        Assert.DoesNotContain("AddScriptToExecuteOnDocumentCreatedAsync", view);
        Assert.DoesNotContain("CallDevToolsProtocolMethodAsync", view);
        Assert.DoesNotContain("document.body.style.zoom", view);
        Assert.Contains("Look.Guard(web, _preview);", view);
        Assert.Contains("core.Navigate(new Uri(_preview).AbsoluteUri);", view);
        // The web view's own Ctrl+wheel / Ctrl+= zoom would grow the page a second time, out of step with the bar.
        Assert.Contains("core.Settings.IsZoomControlEnabled = false;", view);
        var look = Windows("Features/Artifacts/ArtifactViewers.cs");
        Assert.Contains("e.Cancel = true;", look);
        Assert.Contains("if (e.IsUserInitiated) ArtifactActions.OpenOutside(e.Uri);", look);
    }

    [Fact]
    public void ControlKeysZoomOnlyWhileThePageHasTheKeys()
    {
        var view = HtmlView();
        Assert.Contains("PageZoomKeys.All", view);
        Assert.Contains("ScopeOwner = this", view);
        Assert.Contains("e.Handled = true", view);
    }

    [Fact]
    public void TheFilePaneHasTheCompactLevelWhileThePreviewShows_AndThePagesWindowTheFullControls()
    {
        var pane = Windows("Features/Artifacts/ArtifactFilePane.cs");
        Assert.Contains("new PageZoomControls(compact: true)", pane);
        Assert.Matches(new Regex(@"ArtifactHtmlView\s+\w+\s*&&\s*\w+\.Mode\s*==\s*0"), pane);
        var window = Windows("Features/Artifacts/ArtifactWindows.cs");
        Assert.Contains("new PageZoomControls(compact: false)", window);
        var controls = Windows("Features/Artifacts/PageZoomControls.cs");
        foreach (var id in new[] { "page.zoom.out", "page.zoom.in", "page.zoom.level" }) Assert.Contains($"\"{id}\"", controls);
        Assert.Contains("PageZoomWords.LevelName(", controls);
        Assert.Contains("PageZoomMenu.Items(", controls);
        Assert.Contains("RadioMenuFlyoutItem", controls);
        Assert.Contains("PageZoomShared.Level", controls);
        Assert.Contains("_watch?.Dispose()", controls);
    }

    [Fact]
    public void OneLevelIsKeptOnThisPcForEveryPage()
    {
        var controls = Windows("Features/Artifacts/PageZoomControls.cs");
        Assert.Contains("new PageZoomLevel(new JsonFileStore(Path.Combine(AppPaths.Root, \"page-zoom.json\")))", controls);
        Assert.Single(Regex.Matches(string.Join("\n", Directory.EnumerateFiles(Path.Combine(WindowsDir(), "src"), "*.cs", SearchOption.AllDirectories)
            .Select(File.ReadAllText)), @"new PageZoomLevel\("));
    }

    private static string WindowsDir()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return dir;
    }

    private static string CoreDir() => Path.Combine(WindowsDir(), "src", "Hermes.Core");
}
