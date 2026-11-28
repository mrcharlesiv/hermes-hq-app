using Hermes.Core.Artifacts;
using Hermes.Core.Settings;
using HermesHQ.Features.Gateways;
using HermesHQ.Features.Settings;
using HermesHQ.Features.Transcript;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Animation;

namespace HermesHQ;

public sealed partial class MainWindow : Window
{
    /// Main window frame persistence key (App/Mac/MacWindow.swift `HQMacMainWindowFrame`).
    public const string FramePrefKey = "HQMacMainWindowFrame";
    private const int DefaultWidth = 1180, DefaultHeight = 800;
    private const int MinWidth = 640, MinHeight = 480;

    internal WindowShutdown Lifetime { get; } = new();

    private bool _keepsFrame;
    private bool _backdropHooked;
    private string? _lastSavedFrame;

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "HermesHQ.ico"));
        if (AppWindow.Presenter is OverlappedPresenter p) { p.PreferredMinimumWidth = MinWidth; p.PreferredMinimumHeight = MinHeight; }
        RestoreWindowFrame();
        HookGlassBackdrop();
        AppWindow.Changed += (_, e) => { if (e.DidPositionChange || e.DidSizeChange) PersistWindowFrame(); };
        AppWindow.Closing += async (_, args) =>
        {
            PersistWindowFrame(force: true);
            await Lifetime.OnClosingAsync(() => args.Cancel = true, Close);
        };
        Closed += (_, _) =>
        {
            UnhookGlassBackdrop();
            Lifetime.OnClosed(LaunchFlow.Closed);
        };
        Activated += (_, args) =>
        {
            if (AppShutdown.Stopping || Lifetime.IsClosing) return;
            if (args.WindowActivationState == WindowActivationState.Deactivated) DismissToolTips();
        };
        RootGrid.GotFocus += (_, e) =>
        {
            if (AppShutdown.Stopping || Lifetime.IsClosing) return;
            if (e.OriginalSource is DependencyObject d && Microsoft.UI.Xaml.Controls.ToolTipService.GetToolTip(d) == null)
                DismissToolTips();
        };
    }

    /// Restores the main window's saved position and size (`HQMacMainWindowFrame`), clamped within visible screen bounds,
    /// falling back to the 1180×800 default (App/Mac/MacWindow.swift `restoreFrame`).
    private void RestoreWindowFrame()
    {
        try
        {
            if (Automation.Enabled)
            {
                AppWindow.Resize(new global::Windows.Graphics.SizeInt32(DefaultWidth, DefaultHeight));
                return;
            }
            var kept = SettingsWindowLayout.Decode(FilePreferences.Shared.Get(FramePrefKey), minimumWidth: MinWidth, minimumHeight: MinHeight);
            if (kept is { } saved)
            {
                DisplayArea area;
                try
                {
                    area = DisplayArea.GetFromRect(
                        new global::Windows.Graphics.RectInt32(
                            (int)Math.Round(saved.X), (int)Math.Round(saved.Y),
                            (int)Math.Round(saved.Width), (int)Math.Round(saved.Height)),
                        DisplayAreaFallback.Primary);
                }
                catch
                {
                    area = DisplayArea.Primary;
                }
                var work = area.WorkArea;
                var frame = FileWindowPlacement.Inside(saved, new WindowFrame(work.X, work.Y, work.Width, work.Height));
                var w = (int)Math.Round(Math.Max(Math.Min(MinWidth, work.Width), frame.Width));
                var h = (int)Math.Round(Math.Max(Math.Min(MinHeight, work.Height), frame.Height));
                var x = (int)Math.Round(frame.X);
                var y = (int)Math.Round(frame.Y);
                AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32(x, y, w, h));
                _lastSavedFrame = SettingsWindowLayout.Encode(new WindowFrame(x, y, w, h));
                AppLog.Note("mac", $"main window: as left, {w}×{h} at {x},{y}");
            }
            else
            {
                AppWindow.Resize(new global::Windows.Graphics.SizeInt32(DefaultWidth, DefaultHeight));
            }
        }
        catch (Exception ex)
        {
            AppLog.Note("mac", $"main window: frame restore failed ({ex.GetType().Name})");
            AppWindow.Resize(new global::Windows.Graphics.SizeInt32(DefaultWidth, DefaultHeight));
        }
        finally
        {
            _keepsFrame = true;
        }
    }

    private void PersistWindowFrame(bool force = false)
    {
        if (!_keepsFrame || Automation.Enabled || AppShutdown.Stopping || (!force && Lifetime.IsClosing)) return;
        if (AppWindow.Presenter is OverlappedPresenter { State: not OverlappedPresenterState.Restored }) return;
        var f = new WindowFrame(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
        if (f.Width < MinWidth || f.Height < MinHeight) return;
        var encoded = SettingsWindowLayout.Encode(f);
        if (encoded == _lastSavedFrame) return;
        _lastSavedFrame = encoded;
        FilePreferences.Shared.Set(FramePrefKey, encoded);
    }

    private void HookGlassBackdrop()
    {
        if (_backdropHooked) return;
        _backdropHooked = true;
        WindowTransparency.Changed += OnBackdropChanged;
        ThemeService.Changed += OnBackdropChanged;
        if (!Automation.Enabled) GlassShell.ApplyWindowBackdrop(this, RootGrid);
    }

    private void UnhookGlassBackdrop()
    {
        if (!_backdropHooked) return;
        _backdropHooked = false;
        WindowTransparency.Changed -= OnBackdropChanged;
        ThemeService.Changed -= OnBackdropChanged;
    }

    private void OnBackdropChanged()
    {
        if (AppShutdown.Stopping || Lifetime.IsClosing) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (AppShutdown.Stopping || Lifetime.IsClosing) return;
            GlassShell.ApplyWindowBackdrop(this, RootGrid);
        });
    }

    /// The launch: the launch screen while the saved sign-in is read and the gateway opens, then the app, the sign-in
    /// form or the offline screen (Features/Gateways/LaunchFlow.cs).
    public Task StartAsync()
    {
        if (Lifetime.IsClosing) return Task.CompletedTask; // a close delivered by Activate won before launch
        LaunchFlow.AttachWindow(this);
        if (Automation.Enabled)
        {
            RootGrid.Background = Automation.ShotBackground();
            return Automation.RunAsync(this);
        }
        GlassShell.ApplyWindowBackdrop(this, RootGrid);
        WindowsUpdateService.StartBackgroundCheckIfAllowed();
        return LaunchFlow.StartAsync();
    }

    public void ShowShell()
    {
        DismissToolTips();
        Root.Navigate(typeof(ShellPage), null, new DrillInNavigationTransitionInfo());
        Root.BackStack.Clear();
    }

    /// The sign-in form, with a notice saying why it is back.
    public void ShowSignIn(string? message = null) => LaunchFlow.ShowSignIn(notice: message);

    /// Puts a page of the launch flow in the window (launch, offline, onboarding).
    public void ShowRoot(UIElement content)
    {
        DismissSheet();
        DismissToolTips();
        if (Root.Content is RootHostPage { Content: var shown } && shown == content) return;
        if (Root.Content is RootHostPage old) old.Content = null; // free the element before a new page takes it
        Root.Navigate(typeof(RootHostPage), content, new SuppressNavigationTransitionInfo());
        Root.BackStack.Clear();
    }

    /// Closes any open WinUI ToolTip popups on this window's XamlRoot so tooltips never linger across
    /// navigation, sidebar rebuilds, or shell swaps. Leaves dialogs, flyouts, and menus untouched.
    internal void DismissToolTips()
    {
        if (AppShutdown.Stopping || Lifetime.IsClosing || !RootGrid.IsLoaded || Root.XamlRoot is not { } xr) return;
        foreach (var popup in Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(xr))
        {
            if (popup.Child is Microsoft.UI.Xaml.Controls.ToolTip { IsOpen: true } tip)
                tip.IsOpen = false;
        }
    }

    /// Detaches the glass/Mica backdrop, sheet, and root page while XAML is still live (before Drain and Close)
    /// so backdrop/shell teardown callbacks settle on the active DispatcherQueue rather than during ShutdownQueue.
    internal void DetachForQuit()
    {
        PersistWindowFrame(force: true);
        UnhookGlassBackdrop();
        SystemBackdrop = null;
        DismissSheet();
        if (Root.Content is RootHostPage old) old.Content = null;
        if (Root.Content is not null and not EmptyPane)
        {
            Root.Navigate(typeof(EmptyPane), null, new SuppressNavigationTransitionInfo());
            Root.BackStack.Clear();
        }
    }

    internal bool RootScreenLoaded => Root.Content is RootHostPage { Content: FrameworkElement { IsLoaded: true } };

    public bool SheetShown => SheetLayer.Visibility == Visibility.Visible;

    /// A sheet over the window: one at a time; a second replaces the first.
    public void PresentSheet(FrameworkElement content)
    {
        SheetHost.Content = content;
        SheetLayer.Visibility = Visibility.Visible;
    }

    public void DismissSheet()
    {
        SheetHost.Content = null;
        SheetLayer.Visibility = Visibility.Collapsed;
    }

    /// After the browser hand-off, bring the app back to the front.
    public void BringToFront()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } p) p.Restore();
        Activate();
    }
}
