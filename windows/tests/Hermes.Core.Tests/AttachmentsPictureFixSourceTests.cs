using System.Text.RegularExpressions;
using Xunit;

namespace Hermes.Core.Tests;

/// Regression guards for the Windows picture-attachment crash and failure fixes across ChatAttachments,
/// WindowsPhotoNormalizer, AttachmentTray, MediaActions, App.xaml.cs, and the WinAppSDK 1.8 file pickers.
public sealed class AttachmentsPictureFixSourceTests
{
    private static string WinSource(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (dir != null && !File.Exists(Path.Combine(dir, "HermesHQ.sln")))
            dir = Directory.GetParent(dir)?.FullName;
        Assert.NotNull(dir);
        return File.ReadAllText(Path.Combine([dir!, "src", "HermesHQ.Windows", .. parts])).ReplaceLineEndings("\n");
    }

    [Fact]
    public void WindowsPhotoNormalizerPassesSingleFloatForImageQualityAndReadsFilesDirectly()
    {
        var src = WinSource("Features", "Attachments", "WindowsPhotoNormalizer.cs");
        // WinRT BitmapTypedValue(object, PropertyType.Single) throws ArgumentException when given a boxed double.
        Assert.Contains("public const float Quality = 0.85f;", src);
        Assert.Contains("new BitmapTypedValue(Quality, Windows.Foundation.PropertyType.Single)", src);
        // Avoid UWP StorageFile/StorageFolder broker calls that fail on non-canonical or elevated paths.
        Assert.DoesNotContain("StorageFile.GetFileFromPathAsync", src);
        Assert.DoesNotContain("StorageFolder.GetFolderFromPathAsync", src);
        Assert.Contains("AsRandomAccessStream()", src);
    }

    [Fact]
    public void ChatAttachmentsPopulatesPlusMenuSynchronouslyAndUsesWinAppSdkPicker()
    {
        var src = WinSource("Features", "Attachments", "ChatAttachments.cs");
        // Never clear MenuFlyout.Items and await inside Opening (WinUI 3 presenter crash / empty menu on first click).
        Assert.Contains("_menu.Opening += (_, _) => FillMenu();", src);
        Assert.DoesNotContain("FillMenuAsync", src);
        // Defer modal pickers until after the MenuFlyout popup finishes dismissing.
        Assert.Contains("Defer(() => _ = PickPhotosAsync())", src);
        Assert.Contains("Defer(() => _ = PickFilesAsync())", src);
        // Use Windows App SDK 1.8 in-process picker (works unpackaged and elevated).
        Assert.Contains("using Microsoft.Windows.Storage.Pickers;", src);
        Assert.DoesNotContain("using Windows.Storage.Pickers;", src);
        Assert.Contains("new FileOpenPicker(window.AppWindow.Id)", src);
    }

    [Fact]
    public void AttachmentTrayDoesNotReparentThumbnailOnPrepareFinishAndDisablesRingsBeforeRemoval()
    {
        var src = WinSource("Features", "Attachments", "AttachmentTray.cs");
        Assert.Contains("var kindChanged = _a == null || _a.Kind != a.Kind;", src);
        Assert.Contains("VisualTreeHelper.GetParent(_thumb) is Border visualOld", src);
        Assert.Contains("if (child is ProgressRing ring) ring.IsActive = false;", src);
    }

    [Fact]
    public void MediaActionsBitmapAsyncReadsFilesDirectlyWithoutStorageFileBroker()
    {
        var src = WinSource("Features", "Attachments", "MediaActions.cs");
        var at = src.IndexOf("public static async Task<BitmapImage> BitmapAsync(", StringComparison.Ordinal);
        Assert.True(at >= 0);
        var end = src.IndexOf("\n    }\n", at, StringComparison.Ordinal);
        var body = src[at..end];
        Assert.DoesNotContain("StorageFile.GetFileFromPathAsync", body);
        Assert.Contains("FileShare.ReadWrite | FileShare.Delete", body);
        Assert.Contains("AsRandomAccessStream()", body);
    }

    [Fact]
    public void AppUnhandledExceptionNullGuardsException()
    {
        var src = WinSource("App.xaml.cs");
        Assert.DoesNotContain("e.Exception.GetType()", src);
        Assert.Contains("e.Exception?.GetType()", src);
    }

    [Fact]
    public void PhotoPickersAcrossFeaturesUseWinAppSdkFileOpenPicker()
    {
        foreach (var path in new[]
        {
            new[] { "Features", "Attachments", "ChatAttachments.cs" },
            new[] { "Features", "Kanban", "KanbanTaskPanel.cs" },
            new[] { "Features", "Tasks", "TaskPane.cs" },
            new[] { "Features", "Groups", "GroupManageFeature.cs" },
            new[] { "Features", "Settings", "BackgroundsPane.cs" },
        })
        {
            var src = WinSource(path);
            Assert.DoesNotMatch(new Regex(@"(?<!Microsoft\.)Windows\.Storage\.Pickers"), src);
            Assert.Matches(new Regex(@"using Microsoft\.Windows\.Storage\.Pickers;|Microsoft\.Windows\.Storage\.Pickers\.FileOpenPicker"), src);
        }
    }
}
