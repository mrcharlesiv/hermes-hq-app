using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Insights;
using HermesHQ.Features.Settings;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;

namespace HermesHQ.Features.Insights;

/// A tile's page in a WebView2 (App/Chat/Viewer/HTMLPageSheet.swift `prelude` / `__hqApplyTheme`,
/// App/Pages/Artifacts/LiveTiles.swift `tileScript`): the app's resolved theme colours as CSS variables,
/// in-place theme switching via `window.__hqApplyTheme(css, isDark, ground)` + `themeKey`, `window.__hqLegible`
/// legibility pass, `window.hermes.send` and `data-hermes-send` buttons, and PNG snapshot capture.
public static class TileWeb
{
    private sealed class WebThemeState
    {
        public string? ScriptId;
        public string? ThemeKey;
        public bool Talks;
        public bool InTile;
    }

    private static readonly ConditionalWeakTable<WebView2, WebThemeState> States = new();

    /// Resolves the app's current visual palette for `dark` mode from `ThemeService`.
    public static TileThemePalette CurrentPalette(bool dark)
    {
        try
        {
            var tokens = ThemeService.Set.Tokens(dark);
            var desktop = ThemeService.State.DesktopLook;
            var radius = desktop ? (int)Math.Round(ThemeService.State.DesktopRadius, MidpointRounding.AwayFromZero) : 16;
            return new TileThemePalette(
                Label: tokens.Label,
                Label2: tokens.Label2,
                Tint: tokens.Tint,
                Separator: tokens.Separator,
                Card: tokens.GroupedCard,
                Page: tokens.Page,
                Dark: dark,
                Radius: radius);
        }
        catch (Exception)
        {
            return TileWebTheme.DefaultPalette(dark);
        }
    }

    public static string ThemeKey(bool dark) => TileWebTheme.ThemeKey(CurrentPalette(dark));

    public static string Prelude(bool dark, bool talks, bool inTile) =>
        TileWebTheme.PreludeScript(CurrentPalette(dark), talks, inTile);

    /// What a page posted: a button's ask, open, or refresh.
    public sealed record Message(int? Id, string? Prompt, bool Open, bool Refresh);

    public static Message? Read(CoreWebView2WebMessageReceivedEventArgs e)
    {
        JsonNode? n;
        try { n = JsonNode.Parse(e.WebMessageAsJson); } catch (JsonException) { return null; }
        if (n is not JsonObject) return null;
        return new Message((int?)n.Int("id"), n.Str("prompt"), n.Bool("open") == true, n.Bool("refresh") == true);
    }

    /// Answers a button's ask in the page (`window.__hermesAck`).
    public static void Ack(WebView2 web, int id, bool ok, string? error = null)
    {
        var result = ok ? "{ok:true}" : "{ok:false,error:" + JsonSerializer.Serialize(error ?? "undelivered") + "}";
        _ = web.CoreWebView2?.ExecuteScriptAsync($"window.__hermesAck && window.__hermesAck({id}, {result})");
    }

    /// A web view set up for a tile's page: no menus, no zoom, no dev tools, the theme prelude before every load,
    /// links leaving the page opened in the browser.
    public static async Task<bool> PrepareAsync(WebView2 web, bool dark, bool talks, bool inTile)
    {
        try
        {
            var env = await HermesHQ.Services.WebViewEnv.GetAsync();
            await web.EnsureCoreWebView2Async(env);
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException or FileNotFoundException)
        {
            return false;
        }
        var core = web.CoreWebView2;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        SetPreferredColorScheme(core, dark);

        var palette = CurrentPalette(dark);
        var state = States.GetOrCreateValue(web);
        state.Talks = talks;
        state.InTile = inTile;
        state.ThemeKey = TileWebTheme.ThemeKey(palette);
        state.ScriptId = await core.AddScriptToExecuteOnDocumentCreatedAsync(TileWebTheme.PreludeScript(palette, talks, inTile));

        core.NavigationStarting += (sender, a) =>
        {
            // The page itself (NavigateToString's about:blank / data) loads; a link leaving it opens in the browser.
            if (a.Uri.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || a.Uri.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                a.Cancel = true;
                if (Uri.TryCreate(a.Uri, UriKind.Absolute, out var u)) _ = Windows.System.Launcher.LaunchUriAsync(u);
            }
        };
        core.NewWindowRequested += (sender, a) =>
        {
            a.Handled = true;
            if (Uri.TryCreate(a.Uri, UriKind.Absolute, out var u) && u.Scheme is "http" or "https") _ = Windows.System.Launcher.LaunchUriAsync(u);
        };
        web.DefaultBackgroundColor = Microsoft.UI.Colors.Transparent;
        return true;
    }

    /// [28b14acf7] Updates an already-loaded WebView2's CSS variables & ground in place via `window.__hqApplyTheme`
    /// without destroying/recreating the WebView2 control. Returns true only when the page requires a reload
    /// (e.g., canvas/script reading theme colors, or prelude not yet evaluated).
    public static async Task<bool> ApplyThemeAsync(WebView2 web, bool dark)
    {
        if (web.CoreWebView2 is not { } core) return false;
        var palette = CurrentPalette(dark);
        var key = TileWebTheme.ThemeKey(palette);
        var state = States.GetOrCreateValue(web);
        if (state.ThemeKey == key) return false;
        state.ThemeKey = key;

        SetPreferredColorScheme(core, dark);
        try
        {
            if (!string.IsNullOrEmpty(state.ScriptId))
                core.RemoveScriptToExecuteOnDocumentCreated(state.ScriptId);
            state.ScriptId = await core.AddScriptToExecuteOnDocumentCreatedAsync(
                TileWebTheme.PreludeScript(palette, state.Talks, state.InTile));
            var result = await core.ExecuteScriptAsync(TileWebTheme.ApplyThemeScript(palette));
            return TileWebTheme.NeedsReloadAfterThemeApply(result);
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException or ObjectDisposedException)
        {
            return false;
        }
    }

    private static void SetPreferredColorScheme(CoreWebView2 core, bool dark)
    {
        try
        {
            if (core.Profile is { } profile)
                profile.PreferredColorScheme = dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
        }
        catch (Exception) { }
    }

    /// Captures a PNG image snapshot of a rendered tile WebView2 (`Share as Image…`).
    public static async Task<byte[]?> CapturePngAsync(WebView2 web)
    {
        if (web.CoreWebView2 is not { } core) return null;
        try
        {
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            await core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
            stream.Seek(0);
            using var read = stream.AsStreamForRead();
            using var ms = new MemoryStream();
            await read.CopyToAsync(ms);
            return ms.Length > 0 ? ms.ToArray() : null;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException or ObjectDisposedException)
        {
            return null;
        }
    }

    /// Loads a page's text (with a viewport when it has none).
    public static void Show(WebView2 web, string html) => web.NavigateToString(TileFiles.WithViewport(html) ?? html);
}
