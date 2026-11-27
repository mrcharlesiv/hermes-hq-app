using Hermes.Core.Settings;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace HermesHQ.Features.Settings;

/// The screen side of Export / Import / Reset (App/Settings/SettingsNavigator.swift `SettingsFileActions`): the Mac's
/// alerts as ContentDialogs, its share sheet as the Save As picker (FileSavePicker, the file named as the Mac names it)
/// and its document picker as the Open picker (FileOpenPicker, .json only).
internal sealed class SettingsFileUi(FrameworkElement host, Action<string, string> hud) : ISettingsFileUi
{
    private static Window? OwnerWindow() => (Window?)SettingsWindow.Showing ?? App.Window;

    /// [WIN-06] The CI's settings-file walk only (Services/ProofWalks.SettingsFile.cs): the OS Save As and Open pickers
    /// can't be driven on the runner, so while the walk runs these stand in for them with files in its own temp folder.
    /// Null otherwise; nothing else sets them. The dialogs stay the real ones.
    internal static Func<string, byte[], Task<bool>>? SaveOverride { get; set; }
    internal static Func<Task<PickedSettingsFile?>>? PickOverride { get; set; }

    public async Task<bool> ConfirmAsync(string title, string? message, string action)
    {
        // `TextPrompt.confirm`: the action is destructive; Cancel is the default.
        var dialog = new ContentDialog
        {
            Title = title, PrimaryButtonText = action, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
        };
        if (message != null) dialog.Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap };
        return await SafeDialog.ShowAsync(host.XamlRoot, dialog) == ContentDialogResult.Primary;
    }

    public async Task<bool> SaveAsync(string fileName, byte[] data)
    {
        if (SaveOverride is { } save) return await save(fileName, data);
        if (OwnerWindow() is not { } owner) return false;
        var picker = new FileSavePicker(owner.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeChoices.Add("JSON", [".json"]);
        picker.SuggestedFileName = Path.GetFileNameWithoutExtension(fileName);
        try
        {
            var target = await picker.PickSaveFileAsync();
            if (target == null || string.IsNullOrEmpty(target.Path)) return false;
            await File.WriteAllBytesAsync(target.Path, data);
            return true;
        }
        catch (Exception e)
        {
            AppLog.Error("settings", e);
            return false;
        }
    }

    public async Task<PickedSettingsFile?> PickAsync()
    {
        if (PickOverride is { } pick) return await pick();
        if (OwnerWindow() is not { } owner) return null;
        var picker = new FileOpenPicker(owner.AppWindow.Id) { ViewMode = PickerViewMode.List, SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".json");
        PickFileResult? file;
        try { file = await picker.PickSingleFileAsync(); }
        catch (Exception e) { AppLog.Error("settings", e); return null; }
        if (file == null || string.IsNullOrEmpty(file.Path)) return null;
        try
        {
            return new PickedSettingsFile(await File.ReadAllBytesAsync(file.Path));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            AppLog.Note("settings", $"import read failed: {e.GetType().Name}");
            return new PickedSettingsFile(null);
        }
    }

    /// `FailureAlert.present(title:reason:)`: the title, the reason, OK.
    public async void Fail(string title, string reason)
    {
        try
        {
            var dialog = new ContentDialog
            {
                Title = title, Content = new TextBlock { Text = reason, TextWrapping = TextWrapping.Wrap },
                CloseButtonText = "OK", DefaultButton = ContentDialogButton.Close,
            };
            await SafeDialog.ShowAsync(host.XamlRoot, dialog);
        }
        catch (Exception e) { AppLog.Error("settings", e); }
    }

    public void Done(string title, string detail) => hud(title, detail);

    /// The status line under the buttons, read out when it changes (the Mac's `HQAnnounce.say`).
    public static void Announce(FrameworkElement element, string text) =>
        FrameworkElementAutomationPeer.FromElement(element)?.RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted,
            AutomationNotificationProcessing.ImportantMostRecent, text, "settings.file-status");
}
