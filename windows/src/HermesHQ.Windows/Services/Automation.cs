using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Net;
using Hermes.Core.Notifications;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace HermesHQ.Services;

/// The CI's eyes (windows/ci/windows.yml). With HQW_AUTOMATION set to a JSON file
/// {"url","username","password","shots","message"?}, the app signs in to a stand-in gateway, opens the first bot's
/// chat, sends a message, visits every place, saves a PNG of the window at each step, and quits. Nothing here runs
/// unless that variable is set.
public static class Automation
{
    public static bool Enabled => Environment.GetEnvironmentVariable("HQW_AUTOMATION") is { Length: > 0 };
    public static bool AppOnly => Enabled && Environment.GetEnvironmentVariable("HQW_APP_PROOF") == "1";
    internal static Hermes.Core.Shell.DesktopProof? Desktop { get; } =
        Hermes.Core.Shell.DesktopProof.ForRunner(Environment.GetEnvironmentVariable, OperatingSystem.IsWindows());

    /// Walks features add after the places (each is handed Shot): a feature's own pages and states.
    public static readonly List<Func<Func<string, Task>, Task>> Walks = [];

    /// Walks an extra stand-in asks for by name (its "walks": […]), run after its places with that stand-in signed in: a
    /// feature's states that need the stand-in's own data (Kanban's board picker with 8, 9 and 13 boards). A name nobody
    /// registered fails that extra, so the CI sees it.
    public static readonly Dictionary<string, Func<Func<string, Task>, Task>> NamedWalks = [];
    internal static readonly Dictionary<string, Func<Func<string, Task>, ToastQuietProbe, Task>> BoundWalks = new(StringComparer.Ordinal);

    /// What the next shot pictures instead of the main window (a file window's content, set and cleared by the walk
    /// that opened it); null: the main window.
    public static UIElement? ShotOf { get; set; }

    public static async Task RunAsync(MainWindow window)
    {
        // The fresh full step creates this directory before launch. An unreadable/unadmitted plan cannot
        // choose a log destination. A terminal stop is also recorded in the app log, even without this folder.
        var shots = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "shots"));
        string? logDirectory = null;
        bool setupAdmitted = false;
        var log = new List<string>();
        void Note(string s) { log.Add($"{DateTimeOffset.Now:HH:mm:ss.fff} {s}"); AppLog.Note("automation", s); }
        var step = 0;
        Task Shot(string name) => Capture(name, null);
        async Task Capture(string name, ToastQuietProbe? quiet)
        {
            window.Lifetime.RequireOpen();
            await Settle();
            window.Lifetime.RequireOpen(); // the window can close while this walk waits for layout
            quiet?.RecheckChat();
            var file = Path.Combine(shots, $"{++step:00}-{name}.png");
            try
            {
                if (quiet == null) await SaveAsync(ShotOf ?? (UIElement)window.Content, file);
                else await SaveAsync((UIElement)window.Content, file, quiet);
                Note($"shot {file}");
            }
            catch (Exception e) when (quiet == null) { Note($"shot {name} failed: {e.Message}"); }
            window.Lifetime.RequireOpen(); // a shot already in flight is not permission for the walk's next action
        }

        try
        {
            bool projected = Environment.GetEnvironmentVariable("HQW_QUIET_PUSH") != null;
            if (projected || (!AppOnly && Desktop == null)) ToastQuietProbe.RequireRunner(OperatingSystem.IsWindows(), Environment.GetEnvironmentVariable);
            if (!AppOnly && Desktop == null) { Note("walk toasts: toast-quiet-stop/v1 phase=runner gap=runner-not-authorized"); return; }
            if (projected) logDirectory = shots; // both runner guards passed; use only the full step's known directory on parse failure
            JsonNode? parsed;
            try { parsed = JsonNode.Parse(await File.ReadAllTextAsync(Environment.GetEnvironmentVariable("HQW_AUTOMATION")!)); }
            catch (Exception e) when (!AppOnly && e is not OutOfMemoryException) { throw QuietWalkStopped.UnreadablePlan(); }
            window.Lifetime.RequireOpen();
            var cfg = parsed!; // JSON null is a parsed, mismatched plan, not an unreadable file.
            var dispatch = new ReplyWalkDispatch(cfg, NamedWalks, BoundWalks);
            if (projected || (!AppOnly && !ReplyWalkDispatch.IsContrastPass(cfg)))
            {
                ReplyQuietReadback.RequirePlan(cfg);
                dispatch.RequireUnique();
            }
            var extrasOnly = cfg.Get("extrasOnly")?.GetValueKind() == System.Text.Json.JsonValueKind.True;
            if (AppOnly && !extrasOnly) throw new InvalidOperationException("app-only proof requires extrasOnly");
            if (AppOnly && !Hermes.Core.Shell.AppProofPlan.Accepts(cfg["extras"]))
                throw new InvalidOperationException("app-only proof requires the named loopback fixture walks");
            if (!AppOnly)
            {
                // Validate every receipt before adopting even the first synthetic account. The helper may not
                // substitute a different authority or append a custom path, userinfo or query.
                if ((!extrasOnly && cfg.Str("url") != "http://127.0.0.1:9711") || cfg["extras"] is not JsonArray fixtures
                    || fixtures.Any(f => !FixtureAddress(f.Str("url")))) throw new InvalidOperationException("expected loopback fixture receipts");
            }
            shots = cfg.Str("shots") ?? Path.Combine(AppPaths.Root, "shots");
            Directory.CreateDirectory(shots);
            logDirectory = shots;
            setupAdmitted = true;
            window.ShowSignIn();
            await Until(window.Lifetime, () => window.RootScreenLoaded, 10);
            await Shot("sign-in");
            window.Lifetime.RequireOpen();

            // [WIN-60] "extrasOnly": true: a second, short run with Windows set differently (larger text, a contrast
            // theme) goes straight to its extras; the main stand-in, the places and the feature walks are the first run's.
            if (extrasOnly) Note("extras only");
            else
            {
                var gw = GatewayAddress.FromTyped(cfg.Str("url")!);
                var session = await AppState.SignIn.PasswordAsync(gw, cfg.Str("username")!, cfg.Str("password")!, window.Lifetime.StopToken);
                window.Lifetime.RequireOpen(session);
                AppState.Adopt(session);
                window.Lifetime.RequireOpen();
                window.ShowShell();
                await Until(window.Lifetime, () => ChatPage.Current?.IsLoaded == true && ChatPage.Current.MessageCount > 0, 40);
                Note("chat open");
                await Shot("chat");
                window.Lifetime.RequireOpen();

                if (cfg.Str("message") is { } message && ChatPage.Current is { } chat)
                {
                    chat.AutomationSend(message);
                    await Until(window.Lifetime, () => chat.IsBusy, 10);
                    await Until(window.Lifetime, () => !chat.IsBusy, 60);
                    Note("reply settled");
                    await Shot("reply");
                }

                foreach (var place in Places.All)
                {
                    window.Lifetime.RequireOpen();
                    var typeInfo = (Application.Current as Microsoft.UI.Xaml.Markup.IXamlMetadataProvider)?.GetXamlType(place.Page);
                    Note($"opening {place.Id} ({place.Page.Name}, XAML type: {typeInfo?.FullName ?? "missing"})");
                    Navigator.Open(place.Id);
                    await Task.Delay(1500);
                    window.Lifetime.RequireOpen();
                    await Shot("place-" + place.Id);
                }
                foreach (var walk in Walks) { window.Lifetime.RequireOpen(); await walk(Shot); }
            }

            // "extras": [{"url","username","password","tag","places":[…],"walks":[…]?}]: stand-ins with each page's own data,
            // so a page is seen with content, not only the performance stand-in's empty or "not available" state.
            foreach (var extra in (cfg["extras"]?.AsArray() ?? []).OfType<JsonNode>())
            {
                window.Lifetime.RequireOpen();
                var tag = extra.Str("tag") ?? "extra";
                bool reserved = dispatch.Reserves(extra);
                void RequireReservedPlan() { ReplyQuietReadback.RequirePlan(cfg); dispatch.RequireSelection(extra); }
                try
                {
                    if (reserved) RequireReservedPlan();
                    var s2 = await AppState.SignIn.PasswordAsync(GatewayAddress.FromTyped(extra.Str("url")!),
                        extra.Str("username")!, extra.Str("password")!, window.Lifetime.StopToken);
                    window.Lifetime.RequireOpen(s2);
                    if (reserved)
                    {
                        try
                        {
                            RequireReservedPlan();
                            if (s2.IsNous || s2.Address.ToString() != extra.Str("url") || s2.Account.Username != extra.Str("username"))
                                throw QuietWalkStopped.Incomplete();
                        }
                        catch { s2.Dispose(); throw; } // not yet transferred to AppState
                    }
                    AppState.Adopt(s2);
                    window.Lifetime.RequireOpen();
                    if (reserved)
                    {
                        RequireReservedPlan();
                        if (!ReferenceEquals(s2, AppState.Client?.Session)) throw QuietWalkStopped.Incomplete();
                    }
                    window.ShowShell();
                    await Task.Delay(3000);
                    window.Lifetime.RequireOpen();
                    Note($"signed in to {tag}");
                    if (reserved) RequireReservedPlan(); // no generic place navigation for the reserved extra
                    else
                    {
                        foreach (var id in extra["places"]?.AsArray() ?? [])
                        {
                            window.Lifetime.RequireOpen();
                            if (J.AsString(id) is not { } place) continue;
                            Navigator.Open(place);
                            await Task.Delay(2500);
                            window.Lifetime.RequireOpen();
                            await Shot($"{tag}-{place}");
                        }
                    }
                    foreach (var name in extra["walks"]?.AsArray() ?? [])
                    {
                        window.Lifetime.RequireOpen();
                        if (J.AsString(name) is not { } walkName) continue;
                        Note($"{tag} walk {walkName}");
                        await dispatch.RunAsync(extra, tag, walkName, s2, ReplyQuietReadback.Bind, Shot, Capture);
                        window.Lifetime.RequireOpen();
                        Note($"{tag} walk {walkName} finished");
                    }
                }
                catch (QuietWalkStopped) { throw; }
                catch (OperationCanceledException) when (window.Lifetime.IsClosing) { throw; }
                catch (Exception) when (reserved) { throw QuietWalkStopped.Incomplete(); }
                catch (Exception e)
                {
                    Note($"{tag} failed: {e.GetType().Name}: {e.Message.Trim()}");
                    // Where it was thrown (a COMException's message alone doesn't say: CI run 45012966385).
                    foreach (var frame in (e.StackTrace ?? "").Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).Take(8))
                        Note($"{tag}   {frame}");
                    window.Lifetime.RequireOpen();
                    await Shot($"{tag}-failure");
                }
            }
            window.Lifetime.RequireOpen();
            Note("done");
        }
        catch (QuietWalkStopped stop) { Note("walk toasts: " + stop.StopLine); return; }
        catch (OperationCanceledException) when (window.Lifetime.IsClosing) { Note("walk stopped: window closing"); return; }
        catch (Exception) when (!setupAdmitted)
        {
            Note(AppOnly ? "failed: invalid app-only plan" : "walk toasts: toast-quiet-stop/v1 phase=plan gap=not-reply-walk");
            return;
        }
        catch (Exception e)
        {
            Note($"failed: {e.GetType().Name}: {e.Message}");
            if (!window.Lifetime.IsClosing)
            {
                try { await Shot("failure"); }
                catch (WindowShutdown.WalkEnded) { Note("walk stopped: window closing"); }
            }
        }
        finally
        {
            await window.Lifetime.FinishWalkAsync(
                () => logDirectory != null && Directory.Exists(logDirectory)
                    ? File.WriteAllLinesAsync(Path.Combine(logDirectory, "automation.log"), log) : Task.CompletedTask,
                window.Close);
        }
    }

    internal static bool FixtureAddress(string? url) => Hermes.Core.Shell.DesktopProof.FixtureAddress(url);

    private static async Task Until(WindowShutdown lifetime, Func<bool> condition, int seconds)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (true)
        {
            lifetime.RequireOpen();
            if (condition()) return;
            if (DateTime.UtcNow > until) throw new TimeoutException("waited too long");
            await Task.Delay(100);
        }
    }

    private static async Task Settle()
    {
        await Task.Delay(600);
        await Task.Yield();
    }

    // Called only after a matching one-use fixture receipt and the SDK's cold launch. No UI input, full-screen
    // capture, arbitrary path or desktop config; render just the loaded fixture chat into the same evidence folder.
    internal static Task SaveColdFixtureChatAsync(ChatPage chat)
    {
        if (AppState.Client?.Session.Address.ToString() != Hermes.Core.Shell.DesktopProof.Fixture || !chat.IsLoaded
            || chat.StoredId != Hermes.Core.Shell.DesktopProof.Chat || ChatPage.Current != chat)
            throw new InvalidOperationException("not the cold fixture chat");
        return SaveAsync(chat, Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "shots", "toast-cold-opened.png")));
    }

    private static async Task SaveAsync(UIElement element, string file, ToastQuietProbe? quiet = null)
    {
        var bitmap = new RenderTargetBitmap();
        quiet?.RecheckChat();
        await bitmap.RenderAsync(element);
        quiet?.RecheckChat();
        var pixels = (await bitmap.GetPixelsAsync()).ToArray();
        // The reply guard vetoes an open popup; never composite a popup into a reserved frame.
        if (quiet == null) await DrawOpenPopupsAsync(element, pixels, bitmap.PixelWidth, bitmap.PixelHeight);
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        quiet?.RecheckChat();
        var scale = element.XamlRoot?.RasterizationScale ?? 1;
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96 * scale, 96 * scale, pixels);
        await encoder.FlushAsync();
        stream.Seek(0);
        var bytes = new byte[stream.Size];
        await stream.AsStream().ReadExactlyAsync(bytes);
        quiet?.RecheckChat();
        await File.WriteAllBytesAsync(file, bytes);
    }

    /// A RenderTargetBitmap of the window leaves out popups (an open menu flyout); each open one is rendered on its own and
    /// laid over the window's pixels where it shows (premultiplied BGRA, source over).
    private static async Task DrawOpenPopupsAsync(UIElement root, byte[] pixels, int width, int height)
    {
        if (root.XamlRoot is not { } xamlRoot || root.ActualSize.X <= 0) return;
        var scale = width / root.ActualSize.X;
        foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(xamlRoot))
        {
            if (popup.Child is not FrameworkElement child || child.ActualWidth <= 0) continue;
            try
            {
                var layer = new RenderTargetBitmap();
                await layer.RenderAsync(child);
                var src = (await layer.GetPixelsAsync()).ToArray();
                var at = child.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point(0, 0));
                int x0 = (int)Math.Round(at.X * scale), y0 = (int)Math.Round(at.Y * scale);
                FillPopupBackdrop(popup, child, root, pixels, width, height, scale);
                for (var y = 0; y < layer.PixelHeight; y++)
                {
                    var ty = y0 + y;
                    if (ty < 0 || ty >= height) continue;
                    for (var x = 0; x < layer.PixelWidth; x++)
                    {
                        var tx = x0 + x;
                        if (tx < 0 || tx >= width) continue;
                        int s = (y * layer.PixelWidth + x) * 4, d = (ty * width + tx) * 4, keep = 255 - src[s + 3];
                        for (var k = 0; k < 4; k++) pixels[d + k] = (byte)Math.Min(255, src[s + k] + pixels[d + k] * keep / 255);
                    }
                }
            }
            catch (Exception e) { AppLog.Note("automation", $"popup not drawn: {e.GetType().Name}"); }
        }
    }

    /// A menu flyout's fill does not reach a RenderTargetBitmap, so the window under it would show through its rows in a
    /// shot. On WinAppSDK 1.8 the MenuFlyoutPresenter's Background is DesktopAcrylicTransparentBrush (#00000000) and the
    /// fill comes from its SystemBackdrop (AcrylicBackgroundFillColorDefaultBackdrop); older styles used an AcrylicBrush
    /// Background. As ShotBackground does for Mica, the presenter's opaque theme colour is painted over its rounded bounds
    /// first (shots only; the live menu keeps its backdrop). One log line says what was filled, or that nothing was.
    private static void FillPopupBackdrop(Microsoft.UI.Xaml.Controls.Primitives.Popup popup, FrameworkElement popupChild,
        UIElement root, byte[] pixels, int width, int height, double scale)
    {
        var (presenter, colour) = PopupFill(popup, popupChild);
        if (presenter is null)
        {
            AppLog.Note("automation", $"popup fill: none found under {popupChild.GetType().Name}");
            return;
        }
        AppLog.Note("automation", $"popup fill: {presenter.GetType().Name} {colour}");
        var at = presenter.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point(0, 0));
        double left = at.X * scale, top = at.Y * scale, w = presenter.ActualWidth * scale, h = presenter.ActualHeight * scale;
        var r = Math.Min(presenter.CornerRadius.TopLeft * scale, Math.Min(w, h) / 2);
        for (var y = (int)Math.Max(0, Math.Floor(top)); y < Math.Min(height, Math.Ceiling(top + h)); y++)
            for (var x = (int)Math.Max(0, Math.Floor(left)); x < Math.Min(width, Math.Ceiling(left + w)); x++)
            {
                // Inside the rounded rectangle (pixel centres), corners cut at the presenter's radius.
                double px = x + 0.5 - left, py = y + 0.5 - top;
                double cx = px < r ? r - px : px > w - r ? px - (w - r) : 0, cy = py < r ? r - py : py > h - r ? py - (h - r) : 0;
                if (cx * cx + cy * cy > r * r || px < 0 || py < 0 || px > w || py > h) continue;
                var d = (y * width + x) * 4;
                pixels[d] = colour.B; pixels[d + 1] = colour.G; pixels[d + 2] = colour.R; pixels[d + 3] = 255;
            }
    }

    /// The popup's presenter and the opaque colour to paint under it, or (null, _) when nothing in it draws its fill
    /// from a backdrop or acrylic.
    private static (Microsoft.UI.Xaml.Controls.Control? Presenter, Windows.UI.Color Colour) PopupFill(
        Microsoft.UI.Xaml.Controls.Primitives.Popup popup, FrameworkElement popupChild)
    {
        // A ToolTip is left out: one lingering from the walk's last pointer move (open, its words not drawn) came out as
        // a stray light square in CI run 45009956343 (48–52, "popup fill: ToolTip"); shots never show tooltips.
        if (Under(popupChild).OfType<Microsoft.UI.Xaml.Controls.ToolTip>().Any()) return (null, default);
        var controls = Under(popupChild).OfType<Microsoft.UI.Xaml.Controls.Control>().Where(c => c.ActualWidth > 0).ToList();
        foreach (var c in controls)
        {
            if (c is Microsoft.UI.Xaml.Controls.MenuFlyoutPresenter menu && (menu.SystemBackdrop is not null || !IsOpaque(menu.Background)))
                return (menu, OpaqueFill(menu));
            if (c.Background is AcrylicBrush acrylic) return (c, acrylic.FallbackColor);
        }
        // Any other popup that takes its fill from a backdrop: its outermost control, in the same theme colour.
        if (popup.SystemBackdrop is not null && controls.FirstOrDefault(c => !IsOpaque(c.Background)) is { } other)
            return (other, OpaqueFill(other));
        return (null, default);
    }

    private static bool IsOpaque(Brush? brush) => brush is SolidColorBrush { Color.A: 255 };

    /// AcrylicBackgroundFillColorDefaultBrush's FallbackColor in the presenter's own theme (WinUI 1.8 generic.xaml:
    /// #2C2C2C Dark, #F9F9F9 Light); a high-contrast presenter keeps its own opaque window colour.
    private static Windows.UI.Color OpaqueFill(Microsoft.UI.Xaml.Controls.Control presenter)
    {
        if (presenter.Background is SolidColorBrush { Color.A: 255 } solid) return solid.Color;
        return presenter.ActualTheme == ElementTheme.Dark
            ? Microsoft.UI.ColorHelper.FromArgb(255, 0x2C, 0x2C, 0x2C)
            : Microsoft.UI.ColorHelper.FromArgb(255, 0xF9, 0xF9, 0xF9);
    }

    private static IEnumerable<DependencyObject> Under(DependencyObject node)
    {
        yield return node;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
            foreach (var child in Under(VisualTreeHelper.GetChild(node, i))) yield return child;
    }

    /// Mica is see-through in a RenderTargetBitmap; a solid page colour keeps the shots readable. One brush, painted
    /// WinUI's SolidBackgroundFillColorBase for the mode on show (Hermes.Core.Settings.ThemeKeys.ShotGround) on every
    /// ThemeService.Refresh: a lookup through Application.Current.Resources gave the system's light ground under
    /// Appearance › Dark (CI run 45095225249, shot 194) [WIN-THEME-APP-RESOURCES]. Under a Windows contrast theme, the
    /// theme's own window colour.
    public static Brush ShotBackground()
    {
        if (Features.Settings.ThemeService.SystemHighContrast) return (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];
        if (_shotGround == null)
        {
            _shotGround = new SolidColorBrush();
            PaintShotGround(Features.Settings.ThemeService.Dark);
        }
        return _shotGround;
    }

    private static SolidColorBrush? _shotGround;

    /// The shots' ground in this mode (ThemeService.Refresh calls it on every change).
    public static void PaintShotGround(bool dark)
    {
        if (_shotGround == null) return;
        _shotGround.Color = Features.Settings.ThemeService.ToColor(Hermes.Core.Settings.ThemeKeys.ShotGround(dark));
    }
}
