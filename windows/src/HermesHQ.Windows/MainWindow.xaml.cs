using HermesHQ.Services;
using HermesHQ.Features.Gateways;
using HermesHQ.Pages;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Animation;

namespace HermesHQ;

public sealed partial class MainWindow : Window
{
    internal WindowShutdown Lifetime { get; } = new();

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "HermesHQ.ico"));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1180, 800));
        if (AppWindow.Presenter is OverlappedPresenter p) { p.PreferredMinimumWidth = 640; p.PreferredMinimumHeight = 480; }
        AppWindow.Closing += async (_, args) => await Lifetime.OnClosingAsync(() => args.Cancel = true, Close);
        Closed += (_, _) => Lifetime.OnClosed(LaunchFlow.Closed);
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

    /// Detaches the Mica backdrop, sheet, and root page while XAML is still live (before Drain and Close)
    /// so backdrop/shell teardown callbacks settle on the active DispatcherQueue rather than during ShutdownQueue.
    internal void DetachForQuit()
    {
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
