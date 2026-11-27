// Watch Browser's dedicated window (matching Features/Screen/ScreenFeature.cs `ScreenWindow`):
// titled "{Bot}’s Browser", 1080 × 760 initial size (scaled), 480 × 420 minimum size, follows app theme changes,
// covers the live stage when another app takes foreground, handles window shortcuts, and cleanly shuts down the
// viewer on close.

using System.Runtime.InteropServices;
using Hermes.Core.Browser;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Windows.Graphics;
using Windows.System;
using Windows.UI.Core;

namespace HermesHQ.Features.Browser;

internal sealed class BrowserWindow : Window
{
    private static BrowserWindow? _showing;
    public static BrowserWindow? Showing => _showing;
    public static void CloseOpen() => _showing?.Close();

    public BrowserViewerPage Page { get; }
    public BrowserViewerController Viewer { get; }
    private bool _closing;

    public BrowserWindow(BrowserViewerPage page, BrowserViewerController viewer)
    {
        Page = page;
        Viewer = viewer;
        _showing = this;
        Title = viewer.Title;
        Content = page;

        try
        {
            var scale = App.Window?.Content?.XamlRoot?.RasterizationScale ?? 1.0;
            AppWindow.Resize(new SizeInt32((int)(1080 * scale), (int)(760 * scale)));
            if (AppWindow.Presenter is OverlappedPresenter presenter)
            {
                presenter.PreferredMinimumWidth = (int)(480 * scale);
                presenter.PreferredMinimumHeight = (int)(420 * scale);
            }
        }
        catch (Exception e) { AppLog.Note("browser", $"window sizing failed ({e.GetType().Name})"); }

        FollowTheme();
        ThemeService.Changed += FollowTheme;
        page.OnDismiss = () => { if (!_closing) Close(); };
        page.KeyDown += OnPageKeyDown;
        page.Loaded += (_, _) => viewer.Appeared();
        Activated += (_, e) =>
        {
            var active = e.WindowActivationState != WindowActivationState.Deactivated;
            if (active || (App.Window?.AppWindow.IsVisible == true && !AppIsForeground()))
                viewer.AppActiveChanged(active);
        };
        Closed += (_, _) =>
        {
            _closing = true;
            ThemeService.Changed -= FollowTheme;
            viewer.Disappeared();
            viewer.Close();
            page.Dispose();
            if (_showing == this) _showing = null;
            AppLog.Note("browser", "window closed");
        };
        AppLog.Note("browser", "window shown");
    }

    private void OnPageKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down);
        var alt = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu).HasFlag(CoreVirtualKeyStates.Down);
        if (Page.HandleWindowKey(e.Key, ctrl, alt)) e.Handled = true;
    }

    private void FollowTheme()
    {
        if (App.Window?.Content is FrameworkElement main) Page.RequestedTheme = main.RequestedTheme;
    }

    private static bool AppIsForeground()
    {
        var foreground = GetForegroundWindow();
        GetWindowThreadProcessId(foreground, out var pid);
        return pid == (uint)Environment.ProcessId;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
}
