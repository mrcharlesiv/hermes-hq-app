using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Windows.Storage.Pickers;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;

namespace HermesHQ.Features.Attachments;

/// Save, Share, Copy and Open for chat pictures and files (App/Chat/Viewer/MediaActions.swift, FilePreviewPresenter;
/// spec 1x-attachments §9.4–§9.6, §10), the Windows way: Save As… is the save dialog (the Mac's Save to Photos has no
/// Windows library to go to), Share… is the Windows share sheet, a file opens in its own app (the Mac's Quick Look).
internal static class MediaActions
{
    public static IntPtr WindowHandle(Window? window = null) =>
        WinRT.Interop.WindowNative.GetWindowHandle(window ?? App.Window!);

    private static readonly Dictionary<(string, int), WeakReference<BitmapImage>> Bitmaps = [];

    /// A picture decoded at about `decodeWidth` pixels wide (never the full original on screen), shared while alive.
    public static async Task<BitmapImage> BitmapAsync(string path, int decodeWidth)
    {
        if (string.IsNullOrEmpty(path)) throw new FileNotFoundException("Empty image path.");
        if (Bitmaps.TryGetValue((path, decodeWidth), out var weak) && weak.TryGetTarget(out var known)) return known;
        await using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, useAsync: true);
        using var stream = fs.AsRandomAccessStream();
        var bitmap = new BitmapImage();
        if (decodeWidth > 0) bitmap.DecodePixelWidth = decodeWidth;
        await bitmap.SetSourceAsync(stream);
        Bitmaps[(path, decodeWidth)] = new WeakReference<BitmapImage>(bitmap);
        return bitmap;
    }

    /// An alert with OK ("Couldn't Attach", "Couldn't Open File", …).
    public static Task AlertAsync(XamlRoot? root, string title, string message) =>
        SafeDialog.ShowAsync(root, new ContentDialog
        {
            Title = title, Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "OK", DefaultButton = ContentDialogButton.Close,
        });

    /// "Couldn’t Save" / "Couldn’t Share" / "Couldn’t Copy" with what went wrong, and Try Again.
    public static async Task FailureAsync(XamlRoot? root, string title, string message, Func<Task> retry)
    {
        var dialog = new ContentDialog
        {
            Title = title, Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "Cancel", PrimaryButtonText = "Try Again", DefaultButton = ContentDialogButton.Primary,
        };
        if (await SafeDialog.ShowAsync(root, dialog) == ContentDialogResult.Primary) await retry();
    }

    /// A copy named after the picture or file (the gateway file's name), in its own temporary folder, for Share and
    /// Save: the cache's own name is a hash.
    public static string NamedCopy(string path, string name)
    {
        var folder = Path.Combine(Path.GetTempPath(), "HQNShare-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var safe = Hermes.Core.Attachments.AttachmentCenter.SafeName(string.IsNullOrWhiteSpace(name) ? Path.GetFileName(path) : name);
        if (Path.GetExtension(path) is { Length: > 0 } ext && !safe.EndsWith(ext, StringComparison.OrdinalIgnoreCase)
            && Hermes.Core.Attachments.MediaKinds.Kind(safe) == Hermes.Core.Attachments.MediaKind.Other
            && Hermes.Core.Artifacts.FileWindowRoute.For(safe, 1) == Hermes.Core.Artifacts.FileWindowShows.OwnApp)
            safe += ext;
        var target = Path.Combine(folder, safe);
        File.Copy(path, target, overwrite: true);
        return target;
    }

    /// Save As…: the save dialog, named as Share names it. Answers whether it was saved.
    public static async Task<bool> SaveAsAsync(string path, string name, Window? window = null)
    {
        var owner = window ?? App.Window;
        if (owner == null) return false;
        var picker = new FileSavePicker(owner.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.PicturesLibrary };
        var ext = Path.GetExtension(name).Length > 0 ? Path.GetExtension(name) : Path.GetExtension(path);
        if (ext.Length == 0) ext = ".bin";
        picker.FileTypeChoices.Add(ext.TrimStart('.').ToUpperInvariant() + " file", [ext]);
        picker.SuggestedFileName = Path.GetFileNameWithoutExtension(name.Length > 0 ? name : path);
        try
        {
            var target = await picker.PickSaveFileAsync();
            if (target == null || string.IsNullOrEmpty(target.Path)) return false;
            File.Copy(path, target.Path, overwrite: true);
            return true;
        }
        catch (Exception e) { AppLog.Error("attachments", e); return false; }
    }

    /// Share…: the Windows share sheet with a copy named after the picture or file.
    public static async Task ShareAsync(string path, string name, Window? window = null)
    {
        var copy = NamedCopy(path, name);
        var file = await StorageFile.GetFileFromPathAsync(copy);
        var hwnd = WindowHandle(window);
        var manager = DataTransferManagerInterop.GetForWindow(hwnd);
        void OnRequested(DataTransferManager sender, DataRequestedEventArgs args)
        {
            manager.DataRequested -= OnRequested;
            args.Request.Data.Properties.Title = Path.GetFileName(copy);
            args.Request.Data.SetStorageItems([file]);
            if (Hermes.Core.Attachments.MediaKinds.Kind(copy) == Hermes.Core.Attachments.MediaKind.Image)
                args.Request.Data.SetBitmap(RandomAccessStreamReference.CreateFromFile(file));
        }
        manager.DataRequested += OnRequested;
        DataTransferManagerInterop.ShowShareUIForWindow(hwnd);
    }

    /// Copy Image: the picture on the clipboard (as a bitmap and as the file).
    public static async Task CopyImageAsync(string path, string name)
    {
        var file = await StorageFile.GetFileFromPathAsync(NamedCopy(path, name));
        var package = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
        package.SetBitmap(RandomAccessStreamReference.CreateFromFile(file));
        package.SetStorageItems([file]);
        SafeClipboard.TrySetContent(package);
    }

    /// Copy Path: the gateway path, so it can be pasted into a message.
    public static void CopyText(string text) => SafeClipboard.TrySetText(text);

    /// Opens a file: in a window of its own when this app draws it (a page, a note, a PDF, text; MacFileWindow,
    /// FilePreviewPresenter.present), else in its own app (the Mac's Quick Look); Open With when Windows has no app.
    public static async Task OpenAsync(string path, string name)
    {
        if (HermesHQ.Shell.FileWindows.Open?.Invoke(path, name, null) == true) return;
        var file = await StorageFile.GetFileFromPathAsync(NamedCopy(path, name));
        var opened = await Windows.System.Launcher.LaunchFileAsync(file);
        if (!opened)
            await Windows.System.Launcher.LaunchFileAsync(file, new Windows.System.LauncherOptions { DisplayApplicationPicker = true });
        AppLog.Note("attachments", $"opened a {Hermes.Core.Attachments.MediaKinds.Kind(path)} file: {opened}");
    }
}
