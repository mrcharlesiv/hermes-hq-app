using System.Runtime.CompilerServices;
using System.Text.Json;
using Hermes.Core.Chat;
using Hermes.Core.Transcripts;
using HermesHQ.Features.Attachments;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace HermesHQ.Features.Transcript;

/// A page's picture as drawn: its pixels (BGRA, top-down) and its size in the drawing view's points.
public sealed record PagePicture(PagePixels Pixels, double Width, double Height);

/// The page card's pictures (App/Chat/Viewer/PageSnapshots.swift at 93f984bb1; the rules are Hermes.Core's
/// PageSnapshots): the page's file read again the way its window reads it (the chat's MediaStore, fresh, as FileWindows
/// opens it: no new network path), then drawn in an off-screen WebView2 with its scripts and photographed
/// (CapturePreviewAsync). The web view sits in the main window, 10 000 points to the left of it, as the Mac's sits off screen in its key window: a
/// web view only paints in a window. Each look has a WebView2 profile of its own, so a picture's dark or light never
/// changes an open page window's.
internal static class PagePictures
{
    public static readonly PageSnapshots<PagePicture> Shared = new(ReadAsync, DrawAsync);

    private static readonly ConditionalWeakTable<ChatSession, PageTurnEdge> Watched = [];
    private static Canvas? _host;

    /// The chat's page context (account and bot), or null outside a signed-in chat.
    public static PageContext? Context(ChatSession? session) =>
        session != null && AppState.Client is { } client ? new PageContext(client.AccountId, session.Profile) : null;

    /// Hears the chat's turns end (once per chat): a turn ending after the chat ran starts a new generation of its pages'
    /// pictures (ChatViewController: `wasRunning, !session.isRunning` → `PageSnapshots.noteTurnEnded`).
    public static void Watch(ChatSession session)
    {
        if (Watched.TryGetValue(session, out _)) return;
        var edge = new PageTurnEdge();
        Watched.Add(session, edge);
        edge.Saw(session.Busy);
        session.Changed += () => edge.Saw(session.Busy);
        session.TurnEnded += _ =>
        {
            if (AppShutdown.Stopping || !edge.Ended() || Context(session) is not { } context) return;
            App.Window?.DispatcherQueue.TryEnqueue(() => { if (!AppShutdown.Stopping) Shared.NoteTurnEnded(context); });
        };
    }

    /// The page's file on this computer, read again from the bot's computer each time it's drawn (the bot may have
    /// rewritten it; MediaStore.PagePictureFileAsync): null when it's gone there, the kept copy when the read fails
    /// otherwise.
    private static async Task<string?> ReadAsync(string path, string name, PageContext context)
    {
        if (MediaContext.Current is not { } m || m.Profile != context.Profile) return null;
        try { return await m.Center.Media.PagePictureFileAsync(path, name, m.Profile, m.SessionId); }
        catch (Exception e)
        {
            AppLog.Note("page-cards", $"page picture read failed: {e.GetType().Name}");
            return null;
        }
    }

    private static Canvas? Host()
    {
        if (_host is { Parent: not null }) return _host;
        if (App.Window?.Content is not Panel root) return null;
        _host = new Canvas { IsHitTestVisible = false, Width = 0, Height = 0, HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(_host, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        if (root is Grid) Grid.SetRowSpan(_host, 8);
        root.Children.Insert(0, _host);
        return _host;
    }

    /// The page drawn off screen and pictured (`draw`): a phone's screen (390 × 844) for a chat's card; its first chart,
    /// or where its content is, photographed (PageSnapshotRules.ProbeScript); null when it can't be drawn.
    private static async Task<PagePicture?> DrawAsync(string file, bool dark, PageShape shape)
    {
        if (AppShutdown.Stopping || Host() is not { } host) return null;
        var zoom = shape.Zoom;
        var (w, h) = shape.Size;
        var web = new WebView2
        {
            Width = Math.Round(w / zoom), Height = Math.Round(h / zoom), IsHitTestVisible = false, IsTabStop = false,
            DefaultBackgroundColor = dark ? Windows.UI.Color.FromArgb(255, 0x1C, 0x1C, 0x1E) : Microsoft.UI.Colors.White,
        };
        Canvas.SetLeft(web, -10_000);
        host.Children.Add(web);
        try
        {
            var env = await WebViewEnv.GetAsync();
            var options = env.CreateCoreWebView2ControllerOptions();
            options.ProfileName = dark ? "page-pictures-dark" : "page-pictures-light";
            await web.EnsureCoreWebView2Async(env, options);
            var core = web.CoreWebView2;
            core.Profile.PreferredColorScheme = dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
            core.Settings.IsZoomControlEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            var page = new Uri(PageEncoding.DrawableFile(file)).AbsoluteUri;   // [utf8-pages] an undeclared UTF-8 page as UTF-8
            // Only the page itself: nothing it does while being pictured leaves it.
            core.NavigationStarting += (_, e) =>
            {
                if (!e.Uri.StartsWith(page, StringComparison.OrdinalIgnoreCase) && !e.Uri.StartsWith("about:", StringComparison.Ordinal)
                    && !e.Uri.StartsWith("data:", StringComparison.Ordinal)) e.Cancel = true;
            };
            core.NewWindowRequested += (_, e) => e.Handled = true;
            var loaded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            core.NavigationCompleted += (_, e) => loaded.TrySetResult(e.IsSuccess);
            core.ProcessFailed += (_, _) => loaded.TrySetResult(false);
            core.Navigate(page);
            // A page that never finishes loading is given up on, so the line of pictures behind it keeps moving.
            var first = await Task.WhenAny(loaded.Task, Task.Delay(PageSnapshotRules.LoadLimit));
            if (first != loaded.Task || !await loaded.Task) return null;
            await Task.Delay(PageSnapshotRules.Settle);

            if (!shape.IsPhone)
            {
                if (await EvalAsync<bool?>(core, PageSnapshotRules.FitsScript) == true)
                    return await CaptureAsync(web, new PageRect(0, 0, web.Width, web.Height), zoom != 1 ? w : null);
                if (zoom != 1)
                {
                    (web.Width, web.Height) = (w, h);
                    await Task.Delay(PageSnapshotRules.Repaint);
                    if (await EvalAsync<bool?>(core, PageSnapshotRules.FitsScript) == true)
                        return await CaptureAsync(web, new PageRect(0, 0, web.Width, web.Height), null);
                }
                if (shape.IsFrame)
                {
                    (web.Width, web.Height) = shape.FrameAsBox.Size;
                    await Task.Delay(PageSnapshotRules.Repaint);
                }
            }
            var found = await EvalAsync<double[]>(core, PageSnapshotRules.ProbeScript) ?? [];
            if (PageSnapshotRules.CaptureRect(found, web.Width) is not { } rect) return null;
            if (rect.MaxY > web.Height)
            {
                web.Height = rect.MaxY + 20;   // the web view paints only what it covers
                await Task.Delay(PageSnapshotRules.Repaint);
            }
            return await CaptureAsync(web, rect, null);
        }
        catch (Exception e)
        {
            AppLog.Note("page-cards", $"page picture failed: {e.GetType().Name}");
            return null;
        }
        finally
        {
            host.Children.Remove(web);
            try { web.Close(); } catch (Exception) { }
        }
    }

    private static async Task<T?> EvalAsync<T>(CoreWebView2 core, string script)
    {
        try { return JsonSerializer.Deserialize<T>(await core.ExecuteScriptAsync(script)); }
        catch (Exception) { return default; }
    }

    /// The web view's viewport photographed, then cut to `rect` (points → its pixels); `width`: the picture's width in
    /// points when it differs from the view's (a zoomed tile).
    private static async Task<PagePicture?> CaptureAsync(WebView2 web, PageRect rect, double? width)
    {
        using var stream = new InMemoryRandomAccessStream();
        await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        var scale = decoder.PixelWidth / Math.Max(1, web.Width);
        uint X(double v) => (uint)Math.Max(0, Math.Round(v * scale));
        var bounds = new BitmapBounds { X = Math.Min(X(rect.X), decoder.PixelWidth - 1), Y = Math.Min(X(rect.Y), decoder.PixelHeight - 1) };
        bounds.Width = Math.Max(1, Math.Min(X(rect.Width), decoder.PixelWidth - bounds.X));
        bounds.Height = Math.Max(1, Math.Min(X(rect.Height), decoder.PixelHeight - bounds.Y));
        var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            new BitmapTransform { Bounds = bounds }, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
        var pixels = new PagePixels((int)bounds.Width, (int)bounds.Height, data.DetachPixelData());
        var k = width is { } wanted ? wanted / web.Width : 1;
        return new PagePicture(pixels, bounds.Width / scale * k, bounds.Height / scale * k);
    }
}
