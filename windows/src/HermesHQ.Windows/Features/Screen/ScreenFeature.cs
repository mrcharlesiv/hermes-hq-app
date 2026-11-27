using Hermes.Core.Bots;
using Hermes.Core.Net;
using Hermes.Core.Screen;
using Hermes.Core.Composer;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace HermesHQ.Features.Screen;

/// [WIN-SCREEN-PAGE] Bot Screen's hooks into the app (App/Screen/AppModel+Screen.swift at 93f984bb1, §5.1): the
/// account's ScreenService (made for the signed-in client, shut down on a change of account), the bot menu's Screen
/// entry (Watch Screen / View Screen / Latest Screenshots, after View Sessions as BotsOrganizer.menuNodes puts it), and
/// `Open`, the one entry to a bot's Screen. The Mac presents the viewer over the window; Windows opens it in a window of
/// its own beside the main one (closing it comes back to where you were, as UX study #94 asks of the Mac's).
internal static class ScreenFeature
{
    private static ScreenService? _service;
    private static string? _serviceAccount;
    private static readonly IKeyValueStore Prefs = new JsonFileStore(Path.Combine(AppPaths.Root, "screen.json"));

    /// The signed-in account's service, made on first use on the UI thread.
    public static ScreenService? Service
    {
        get
        {
            var client = AppState.Client;
            if (client == null) { Drop(); return null; }
            if (_service != null && _serviceAccount == client.AccountId) return _service;
            Drop();
            _service = ScreenService.For(client, new ScreenHolds(Prefs));
            _service.Note = line => AppLog.Note("screen", line);
            _serviceAccount = client.AccountId;
            return _service;
        }
    }

    private static void Drop()
    {
        ScreenWindow.CloseOpen();
        _service?.Shutdown();
        _service = null;
        _serviceAccount = null;
    }

    /// The bot menu's entry (BotMenuHooks.providers[.screen]): its label read when the menu is built, no request made.
    public static MenuFlyoutItem? MenuItem(BotRow bot)
    {
        if (Service is not { } screen) return null;
        var kind = screen.Kind(bot.Id);
        var item = new MenuFlyoutItem { Text = kind.MenuTitle(), Icon = new FontIcon { Glyph = kind == ScreenKind.Screenshots ? "\uE91B" : "\uE7F4" } };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(item, "bot-menu.screen");
        item.Click += (_, _) => Open(bot.Id, bot.Name);
        return item;
    }

    /// AppModel.openScreen(profile:name:from:): the bot's Screen, unless one is already open (that one comes forward).
    public static ScreenViewerPage? Open(string profile, string name)
    {
        if (Service is not { } screen) return null;
        return Open(profile, name, screen, viewer =>
        {
            if (AppState.Client is not { } client) return;
            // [WIN-SCREEN-SETUP-SEND] Set Up with Hermes: the Screen closes, the bot's chat opens and the request goes
            // out in it (the ledger keeps it to one at a time per bot, so the requester's unledgered run is used here).
            ScreenSetupLedger.Shared.Configure(viewer, client.AccountId,
                request: resume => Requester.RunAsync(profile, resume),
                openCloudAgent: null, ownsSession: null);
        });
    }

    /// `requestScreenSetup` over the app (Hermes.Core ScreenSetupRequester, Features/Screen/ScreenSetupHost.cs).
    public static ScreenSetupRequester Requester { get; } = new(new ScreenSetupHost());

    /// The viewer over any service (the walk's stand-in too): a window holding the page, its controller loaded.
    public static ScreenViewerPage? Open(string profile, string name, ScreenService service, Action<ScreenViewerController>? configure)
    {
        if (ScreenViewerController.Current != null) { ScreenWindow.Showing?.Activate(); return ScreenWindow.Showing?.Page; }
        var page = new ScreenViewerPage { ControlSetup = ScreenSetupSheet.PresentAsync };   // the notes' Enable Control
        var queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        var viewer = ScreenViewerController.Open(profile, name, service, page, new DispatcherScreenTimers(queue), new RenderingScreenTicks(), configure);
        if (viewer == null) return null;
        var window = new ScreenWindow(page, viewer);
        page.Attach(viewer);
        window.Activate();
        return page;
    }

    /// The fallback page's gateway for its screenshot feed (the signed-in client, or a stand-in that is one).
    public static IScreenshotGateway? FeedGateway(ScreenViewerController viewer) =>
        (_service != null && viewer.Session != null ? _service.Client : null) as IScreenshotGateway ?? Stand?.Invoke();

    /// The walk's stand-in gateway, when the viewer runs over one.
    public static Func<IScreenshotGateway?>? Stand { get; set; }

    /// Maximum bytes accepted for a single gateway screenshot download (25 MiB).
    private const long ShotCeilingBytes = 25 * 1024 * 1024;

    /// A gateway path's picture (App/Chat/ActivityCells.swift `ActivityMedia.loadFullDirect`): GET `/api/fs/download`
    /// with `path` and optional `profile` through the signed-in gateway session. Settable for tests and walks.
    public static Func<string, string, Task<byte[]?>>? LoadShot { get; set; } = DefaultLoadShotAsync;

    private static async Task<byte[]?> DefaultLoadShotAsync(string path, string profile)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        if (AppState.Client?.Session is not { } session) return null;
        var resolved = path.StartsWith("file://", StringComparison.OrdinalIgnoreCase)
            && Uri.TryCreate(path, UriKind.Absolute, out var uri)
            ? Uri.UnescapeDataString(uri.AbsolutePath)
            : path;
        var query = new List<KeyValuePair<string, string>> { new("path", resolved) };
        if (!string.IsNullOrWhiteSpace(profile)) query.Add(new("profile", profile));
        var temp = Path.Combine(Path.GetTempPath(), "HQNScreenShot-" + Guid.NewGuid().ToString("N") + ".img");
        try
        {
            await session.DownloadToFileAsync("/api/fs/download", query, temp, ShotCeilingBytes);
            return await File.ReadAllBytesAsync(temp);
        }
        finally
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            try { if (File.Exists(temp + ".partial")) File.Delete(temp + ".partial"); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}

/// [WIN-SCREEN-PAGE] The window a bot's Screen opens in: titled as the page ("Otto’s Screen"), 1000 × 700 at first, no
/// smaller than 480 × 360. Closing it leaves the Screen (the controller's Left: hands back, stops every timer, lets the
/// display sleep); the page's Close, Ctrl+W and Escape close it. App not active: the picture is covered (D17).
internal sealed class ScreenWindow : Window
{
    private static ScreenWindow? _showing;
    public static ScreenWindow? Showing => _showing;
    public static void CloseOpen() => _showing?.Close();

    public ScreenViewerPage Page { get; }
    private readonly ScreenViewerController _viewer;
    private bool _closing;

    public ScreenWindow(ScreenViewerPage page, ScreenViewerController viewer)
    {
        Page = page;
        _viewer = viewer;
        _showing = this;
        Title = viewer.Title;
        Content = page;
        try
        {
            var scale = App.Window?.Content?.XamlRoot?.RasterizationScale ?? 1;
            AppWindow.Resize(new global::Windows.Graphics.SizeInt32((int)(1000 * scale), (int)(700 * scale)));
            if (AppWindow.Presenter is OverlappedPresenter p)
            {
                p.PreferredMinimumWidth = (int)(480 * scale);
                p.PreferredMinimumHeight = (int)(360 * scale);
            }
        }
        catch (Exception e) { AppLog.Note("screen", $"window: sizing failed ({e.GetType().Name})"); }
        FollowTheme();
        ThemeService.Changed += FollowTheme;
        page.OnDismiss = () => { if (!_closing) Close(); };
        page.KeyDown += Keys;
        page.Loaded += (_, _) => viewer.Appeared();
        Activated += (_, e) =>
        {
            var active = e.WindowActivationState != WindowActivationState.Deactivated;
            // Another window of the app in front is not the app going away: only a whole-app switch covers the picture.
            if (active || App.Window?.AppWindow.IsVisible == true && !AppIsForeground()) viewer.AppChanged(active, background: false);
        };
        Closed += (_, _) =>
        {
            _closing = true;
            ScreenSetupSheet.CloseOpen();   // the sheet goes with the Screen under it
            ThemeService.Changed -= FollowTheme;
            viewer.Left();
            page.Fallback?.Stop();
            page.KeepAwake(false);
            if (_showing == this) _showing = null;
            AppLog.Note("screen", "window: closed");
        };
        AppLog.Note("screen", "window: shown");
    }

    private static bool AppIsForeground()
    {
        var foreground = GetForegroundWindow();
        GetWindowThreadProcessId(foreground, out var pid);
        return pid == (uint)Environment.ProcessId;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    private void Keys(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(global::Windows.System.VirtualKey.Control)
            .HasFlag(global::Windows.UI.Core.CoreVirtualKeyStates.Down);
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(global::Windows.System.VirtualKey.Shift)
            .HasFlag(global::Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (Page.Key(e.Key, ctrl, shift)) e.Handled = true;
    }

    private void FollowTheme()
    {
        if (App.Window?.Content is FrameworkElement main) Page.RequestedTheme = main.RequestedTheme;
    }
}
