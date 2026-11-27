using Hermes.Core.Notifications;
using Hermes.Core.Shell;
using HermesHQ.Features.Notifications;
using HermesHQ.Pages;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Services;

internal static partial class ReplyQuietReadback
{
    private sealed partial class WindowsReader
    {
        // Keep this in inspection order: no snapshots, retries, focus changes or reads past the first refusal.
        public QuietForeground ReadFixtureForeground(QuietChat expected)
        {
            var stored = expected switch { QuietChat.A => ChatA, QuietChat.B => ChatB, _ => null };
            if (stored == null) return QuietForeground.ExpectedChatUnknown;
            if (App.Window is not { } window) return QuietForeground.WindowMissing;
            if (!window.DispatcherQueue.HasThreadAccess) return QuietForeground.NotUiThread;
            if (window.SheetShown) return QuietForeground.SheetShown;
            if (window.Content is not FrameworkElement content) return QuietForeground.ContentNotElement;
            if (content.XamlRoot is not { } root) return QuietForeground.RootMissing;

            if (ShellPage.Current is not { } shell) return QuietForeground.ShellMissing;
            if (!shell.IsLoaded) return QuietForeground.ShellNotLoaded;
            if (shell.XamlRoot != root) return QuietForeground.ShellRootMismatch;
            if (shell.KeyState() is not { } open) return QuietForeground.ShellStateMissing;
            if (!open.Online) return QuietForeground.ShellOffline;
            if (open.Pane is not (OpenPane.Chat or OpenPane.BotChat)) return QuietForeground.NotChatPane;
            if (open.StoredId != stored) return QuietForeground.ShellChatMismatch;
            if (ChatPage.Current is not { } page) return QuietForeground.ChatMissing;
            if (!page.IsLoaded) return QuietForeground.ChatNotLoaded;
            if (page.StoredId != stored) return QuietForeground.ChatIdMismatch;
            if (page.XamlRoot != root) return QuietForeground.ChatRootMismatch;
            if (!NotificationsFeature.Tracks(stored)) return QuietForeground.ChatNotTracked;

            if (VisualTreeHelper.GetOpenPopupsForXamlRoot(root).Any(p => p.IsOpen)) return QuietForeground.OpenPopup;
            if (page.FindName("Composer") is not TextBox composer) return QuietForeground.ComposerNotTextBox;
            if (!composer.IsEnabled) return QuietForeground.ComposerDisabled;
            if (composer.Visibility != Visibility.Visible) return QuietForeground.ComposerNotVisible;
            if (!ReferenceEquals(FocusManager.GetFocusedElement(root), composer)) return QuietForeground.ComposerNotFocused;
            var own = WinRT.Interop.WindowNative.GetWindowHandle(window);
            if (own == IntPtr.Zero) return QuietForeground.OwnedHandleMissing;
            return own == GetForegroundWindow() ? QuietForeground.Verified : QuietForeground.ForegroundNotOwned;
        }
    }
}
