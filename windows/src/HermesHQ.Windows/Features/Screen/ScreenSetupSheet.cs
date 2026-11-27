using Hermes.Core.Screen;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Screen;

/// [WIN-SCREEN-SETUP-SEND] "Screen Control" (App/Screen/ScreenSetupCard.swift `ScreenSetupSheet` and
/// ScreenViewerController.swift `showControlSetup` at 93f984bb1, §5.9): the control-only setup card ("Enable Screen
/// Control", Enable Control with Hermes, Check Setup) as a sheet over a live Mac Screen, so it never covers the picture.
/// The notes' Enable Control row opens it (ScreenViewerController.EnableControl → the page's ControlSetup); the Screen
/// under it pauses its stream while it is up. Closed by Done, Escape, or the Screen's window closing.
internal static class ScreenSetupSheet
{
    private static ContentDialog? _open;

    /// The card on show, for the walks.
    public static ScreenSetupCard? Card { get; private set; }
    public static bool IsOpen => _open != null;

    /// Shows the sheet over the page; finishes when it has gone.
    public static async Task PresentAsync(ScreenViewerPage page)
    {
        if (_open != null || page.XamlRoot is not { } root) return;
        var state = ScreenSetupSheetModel.Card(page.Viewer);
        state.Announce = page.Announce;
        var card = new ScreenSetupCard(state);
        var dialog = new ContentDialog
        {
            Title = ScreenSetupSheetModel.Title,
            CloseButtonText = ScreenSetupSheetModel.Close,
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = root,
            RequestedTheme = page.RequestedTheme,
            Content = new ScrollViewer
            {
                Content = card, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MinWidth = 360, MaxWidth = 520,
                Padding = new Thickness(0, 12, 0, 24),
            },
        };
        AutomationProperties.SetAutomationId(dialog, ScreenSetupSheetModel.AutomationId);
        AutomationProperties.SetName(dialog, ScreenSetupSheetModel.Title);
        _open = dialog;
        Card = card;
        AppLog.Note("screen", "control setup: shown");
        try { await dialog.ShowAsync(); }
        catch (Exception e) { AppLog.Error("screen", e); }   // another dialog was already up in this window
        finally
        {
            _open = null;
            Card = null;
            AppLog.Note("screen", "control setup: gone");
        }
    }

    /// The Screen under it is closing (its window, or a setup request opening the bot's chat).
    public static void CloseOpen() => _open?.Hide();
}
