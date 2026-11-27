using Hermes.Core.Artifacts;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace HermesHQ.Features.Artifacts;

/// The Windows ways of the Mac's artifact actions: links open in the browser, Copy Path / Link is the clipboard,
/// Share… the Windows share sheet, Save As… the save dialog, Show in Chat the chat itself.
internal static class ArtifactActions
{
    public static IntPtr Handle(Window? window) => WinRT.Interop.WindowNative.GetWindowHandle(window ?? App.Window!);

    /// Only http(s) ever leaves the app.
    public static void OpenOutside(string value)
    {
        if (Uri.TryCreate(value, UriKind.Absolute, out var url) && url.Scheme is "http" or "https")
            _ = Windows.System.Launcher.LaunchUriAsync(url);
    }

    public static void Copy(string text) => SafeClipboard.TrySetText(text);

    public static void ShowInChat(ArtifactRecord record) =>
        Navigator.Go(new ChatDestination(record.Profile ?? "default", record.SessionId, record.SessionTitle));

    /// A copy named after the artifact, in its own folder (the kept file's folder is a hash).
    private static string Named(string path, string name)
    {
        var folder = Path.Combine(Path.GetTempPath(), "HQNShare-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var safe = string.Concat((name.Length > 0 ? name : Path.GetFileName(path)).Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c));
        var target = Path.Combine(folder, safe);
        File.Copy(path, target, overwrite: true);
        return target;
    }

    public static async Task ShareFileAsync(string path, string name, Window? window = null)
    {
        var file = await StorageFile.GetFileFromPathAsync(Named(path, name));
        var hwnd = Handle(window);
        var manager = DataTransferManagerInterop.GetForWindow(hwnd);
        void OnRequested(DataTransferManager sender, DataRequestedEventArgs args)
        {
            manager.DataRequested -= OnRequested;
            args.Request.Data.Properties.Title = file.Name;
            args.Request.Data.SetStorageItems([file]);
        }
        manager.DataRequested += OnRequested;
        DataTransferManagerInterop.ShowShareUIForWindow(hwnd);
    }

    /// A link (or a picture on another site) shares as its address.
    public static void ShareLink(string value, Window? window = null)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var url)) return;
        var hwnd = Handle(window);
        var manager = DataTransferManagerInterop.GetForWindow(hwnd);
        void OnRequested(DataTransferManager sender, DataRequestedEventArgs args)
        {
            manager.DataRequested -= OnRequested;
            args.Request.Data.Properties.Title = value;
            args.Request.Data.SetWebLink(url);
        }
        manager.DataRequested += OnRequested;
        DataTransferManagerInterop.ShowShareUIForWindow(hwnd);
    }

    public static async Task<bool> SaveAsAsync(string path, string name, Window? window = null)
    {
        var owner = window ?? App.Window;
        if (owner == null) return false;
        var picker = new FileSavePicker(owner.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
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
        catch (Exception e) { AppLog.Error("artifacts", e); return false; }
    }

    /// Opens the file in its own app (the Mac's "Open in <app>"); Open With when Windows has none.
    public static async Task OpenInDefaultAppAsync(string path, string name)
    {
        var file = await StorageFile.GetFileFromPathAsync(Named(path, name));
        if (!await Windows.System.Launcher.LaunchFileAsync(file))
            await Windows.System.Launcher.LaunchFileAsync(file, new Windows.System.LauncherOptions { DisplayApplicationPicker = true });
    }

    /// An alert with OK ("Couldn’t Open report.pdf").
    public static Task AlertAsync(XamlRoot? root, string title, string message) =>
        SafeDialog.ShowAsync(root, new ContentDialog
        {
            Title = title, Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "OK", DefaultButton = ContentDialogButton.Close,
        });

    /// Remove's question (PinActions.confirmRemove): what goes, what stays, that it can't be undone.
    public static async Task<bool> ConfirmRemoveAsync(XamlRoot? root, ArtifactRecord record)
    {
        var dialog = new ContentDialog
        {
            Title = ArtifactPageWords.RemoveTitle(record.Label),
            Content = new TextBlock { Text = ArtifactPageWords.RemoveMessage, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = ArtifactPageWords.RemoveAction, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
        };
        return await SafeDialog.ShowAsync(root, dialog) == ContentDialogResult.Primary;
    }

    /// Segoe Fluent Icons for the Mac's SF Symbols (`ArtifactPageWords.Glyph`).
    public static string Glyph(string symbol) => symbol switch
    {
        "link" => "\uE71B",
        "photo" => "\uEB9F",
        "safari" => "\uE774",
        "doc.text" => "\uE8A5",
        "doc.richtext" => "\uEA90",
        "tablecells" => "\uE80A",
        "music.note" => "\uE8D6",
        "film" => "\uE8B2",
        "doc.zipper" => "\uE7B8",
        _ => "\uE7C3",
    };

    public static void Log(string text) => AppLog.Note("artifacts", text);
}
