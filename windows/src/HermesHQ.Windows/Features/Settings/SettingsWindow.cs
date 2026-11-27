using Hermes.Core.Artifacts;
using Hermes.Core.Settings;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace HermesHQ.Features.Settings;

/// [mac-layout] Settings in a window of its own (App/Mac/MacSettingsWindow.swift, SettingsSceneDelegate; owner
/// 2026-11-09 "set it up the way that it should be set up"): Ctrl+, (the Mac's ⌘,), the sidebar foot's gear and Sidebar
/// Settings… open it, or bring it forward when it is open; it sits beside the main window, which keeps what it shows.
/// The window holds the same SettingsPage the main window used to (the categories and search at the left, the page
/// beside them), titled "Settings", 860 × 640 beside the main window or where it was left, no smaller than 693 × 462.
/// Ctrl+W closes it (never the main window's chat); Escape takes one step (a dialog, the search, back a page) and never
/// closes it. Signed out, or with the main window closed, it closes; nothing reopens it at the next launch. The
/// decisions are Hermes.Core/Settings/SettingsWindow.cs.
internal sealed class SettingsWindow : Window
{
    private static readonly SettingsWindowRegistry<SettingsWindow> Registry = new();
    private readonly Grid _root = new();
    private readonly Frame _frame = new();
    internal const double CaptionHeight = 32;
    private bool _keeps;

    /// The open window (the CI's settings-window walk), and how many there are.
    internal static SettingsWindow? Showing => Registry.Open;
    internal static int OpenCount => Registry.Count;

    /// The Settings page in the window.
    internal SettingsPage? Page => _frame.Content as SettingsPage;

    /// MacSettingsWindow.open / open(then:): the window, opened or brought forward, showing `argument` (a page or row,
    /// as Navigator.Open("settings", …) takes it) when one is asked. False: no main window to sit beside (the sign-in
    /// form) or the window couldn't be made; Settings then opens where it did.
    public static bool Open(string? argument)
    {
        var step = SettingsWindowPlan.Open(Navigator.Listening && App.Window != null && AppState.Client != null, Registry.Open != null, argument);
        if (step.Outcome == SettingsWindowOutcome.InMainWindow) return false;
        var result = Registry.Show(() => new SettingsWindow(argument));
        switch (result.Outcome)
        {
            case FileWindowOutcome.Opened:
                AppLog.Note("mac", "settings window: open");
                result.Window!.Activate();
                return true;
            case FileWindowOutcome.BroughtForward:
                AppLog.Note("mac", "settings window: to the front");
                var shown = result.Window!;
                if (step.Show is { } page && shown.Page is { } settings) settings.ShowAsAsked(page, step.BackToIndex);
                shown.AppWindow.Show(true);
                shown.Activate();
                return true;
            default:
                AppLog.Note("mac", "settings window: couldn't open");
                return false;
        }
    }

    /// MacSettingsWindow.close.
    public static void CloseOpen() => Registry.Open?.Close();

    private SettingsWindow(string? argument)
    {
        Title = SettingsWindowLayout.Title;   // the taskbar and Alt+Tab name it
        ExtendsContentIntoTitleBar = true;
        Place();
        // `titleVisibility = .hidden`, no toolbar: a bare strip to drag by, with the caption buttons over it.
        var drag = new Grid { Height = CaptionHeight, Background = new SolidColorBrush(Colors.Transparent) };
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        // Only the divider draws under the caption. Keep the original full-width drag target above the frame.
        Grid.SetRowSpan(_frame, 2);
        _root.Children.Add(_frame);
        _root.Children.Add(drag);
        AutomationProperties.SetAutomationId(_root, "settings.window");
        AddKeys();
        Content = _root;
        SetTitleBar(drag);
        FollowTheme();
        ThemeService.Changed += FollowTheme;
        _frame.Navigate(typeof(SettingsPage), new SettingsPage.WindowRoute(argument));
        FollowSystemPalette();
        AppWindow.Changed += (_, e) => { if (e.DidPositionChange || e.DidSizeChange) Keep(); };
        Closed += (_, _) =>
        {
            ThemeService.Changed -= FollowTheme;
            Page?.Leaving();
            Registry.Closed(this);
            AppLog.Note("mac", "settings window: closed");
        };
        AppLog.Note("mac", "settings window: shown");
    }

    /// Light or Dark and the skin's face as the main window has them (ThemeService paints the shared brushes).
    private void FollowTheme()
    {
        if (App.Window?.Content is FrameworkElement main) _root.RequestedTheme = main.RequestedTheme;
        if (ThemeService.State.DesktopLook && ThemeService.State.Skin.SansFamily is { } family) _frame.FontFamily = new FontFamily(family);
        else _frame.ClearValue(Control.FontFamilyProperty);
    }

    // WinUI need not raise ActualThemeChanged on entry to high contrast. Observe this window's contrast mode
    // and scheme, plus edits to colours inside the same scheme. Neither requires rebuilding a focused control.
    private void FollowSystemPalette()
    {
        var theme = Microsoft.UI.System.ThemeSettings.CreateForWindowId(AppWindow.Id);
        var colours = new Windows.UI.ViewManagement.UISettings();
        var queue = DispatcherQueue;
        bool open = true;
        void Repaint()
        {
            if (!open) return; // a notification may already be queued at close
            ThemeService.RefreshContrastBrushes();
            _root.Background = Automation.Enabled ? Automation.ShotBackground() : Kit.B("HQGroupedBrush");
            Page?.ApplyWindowPalette();
        }
        void Changed(object sender, object args) => queue.TryEnqueue(Repaint);
        theme.Changed += Changed;
        colours.ColorValuesChanged += Changed;
        Closed += (_, _) =>
        {
            open = false;
            theme.Changed -= Changed;
            colours.ColorValuesChanged -= Changed;
        };
        Repaint(); // the OS palette may have changed while Settings was closed
    }

    /// SettingsSceneDelegate's frame: where it was left, else beside the main window, else in the middle of the screen;
    /// inside the screen's visible part. Its minimum size.
    private void Place()
    {
        try
        {
            var scale = App.Window?.Content?.XamlRoot?.RasterizationScale ?? 1;
            var kept = SettingsWindowLayout.Decode(FilePreferences.Shared.Get(SettingsWindowLayout.FrameKey));
            WindowFrame? main = App.Window is { } w ? new WindowFrame(w.AppWindow.Position.X, w.AppWindow.Position.Y, w.AppWindow.Size.Width, w.AppWindow.Size.Height) : null;
            var areaOf = App.Window is { } mw ? DisplayArea.GetFromWindowId(mw.AppWindow.Id, DisplayAreaFallback.Nearest) : DisplayArea.Primary;
            if (kept is { } k)
                areaOf = DisplayArea.GetFromRect(new global::Windows.Graphics.RectInt32((int)k.X, (int)k.Y, (int)k.Width, (int)k.Height), DisplayAreaFallback.Nearest);
            var area = areaOf.WorkArea;
            var frame = SettingsWindowLayout.Frame(kept, main, new WindowFrame(area.X, area.Y, area.Width, area.Height), scale);
            AppLog.Note("mac", $"settings window: {(kept == null ? "" : "as left, ")}{(int)frame.Width}×{(int)frame.Height}");
            AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32((int)frame.X, (int)frame.Y, (int)frame.Width, (int)frame.Height));
            if (AppWindow.Presenter is OverlappedPresenter p)
            {
                p.PreferredMinimumWidth = (int)(SettingsWindowLayout.MinimumWidth * scale);
                p.PreferredMinimumHeight = (int)(SettingsWindowLayout.MinimumHeight * scale);
            }
        }
        catch (Exception e) { AppLog.Note("mac", $"settings window: placing failed ({e.GetType().Name})"); }
        _keeps = true;
    }

    /// [mac-feel D29] Every move and resize: where it is now is where it opens next time. Maximised or minimised is a
    /// state of the window, not a frame to come back at.
    private void Keep()
    {
        if (!_keeps || AppWindow.Presenter is OverlappedPresenter { State: not OverlappedPresenterState.Restored }) return;
        var f = new WindowFrame(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
        if (!f.IsEmpty) FilePreferences.Shared.Set(SettingsWindowLayout.FrameKey, SettingsWindowLayout.Encode(f));
    }

    /// Ctrl+W, Escape and Ctrl+, in the window (SettingsWindowKeys.Route).
    private void AddKeys()
    {
        void Route(SettingsWindowKeyPress press, KeyboardAcceleratorInvokedEventArgs e)
        {
            var page = Page;
            var over = _root.XamlRoot is { } x && VisualTreeHelper.GetOpenPopupsForXamlRoot(x).Any(p => p.Child is ContentDialog);
            switch (SettingsWindowKeys.Route(press, over, page?.Searching == true, page?.CanGoBack == true))
            {
                case SettingsWindowKeyAction.CloseWindow: e.Handled = true; AppLog.Note("keys", "close window (settings)"); Close(); break;
                case SettingsWindowKeyAction.ClearSearch: e.Handled = true; page!.ClearSearch(); break;
                case SettingsWindowKeyAction.GoBack: e.Handled = true; page!.Back(); break;
                case SettingsWindowKeyAction.BringForward: e.Handled = true; Open(null); break;
                case SettingsWindowKeyAction.Nothing: e.Handled = press != SettingsWindowKeyPress.Escape; break;
                default: e.Handled = false; break;   // the dialog closes on its own Escape
            }
        }
        var esc = new KeyboardAccelerator { Key = VirtualKey.Escape };
        esc.Invoked += (_, e) => Route(SettingsWindowKeyPress.Escape, e);
        var w = new KeyboardAccelerator { Key = VirtualKey.W, Modifiers = VirtualKeyModifiers.Control };
        w.Invoked += (_, e) => Route(SettingsWindowKeyPress.CtrlW, e);
        var comma = new KeyboardAccelerator { Key = (VirtualKey)188, Modifiers = VirtualKeyModifiers.Control };   // VK_OEM_COMMA
        comma.Invoked += (_, e) => Route(SettingsWindowKeyPress.CtrlComma, e);
        _root.KeyboardAccelerators.Add(esc);
        _root.KeyboardAccelerators.Add(w);
        _root.KeyboardAccelerators.Add(comma);
        _root.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
    }
}
