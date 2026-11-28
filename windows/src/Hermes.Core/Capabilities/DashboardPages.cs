using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Settings;

namespace Hermes.Core.Capabilities;

// Port of HermesKit/Plugins/DashboardPages.swift, App/Capabilities/PluginPages/PluginWebPage.swift (pure bridge/theme/
// asset-guard/restart helpers), PluginPagesSection.swift, and PluginPagesMore.swift (merge & bounded discovery).
//
// Upstream Hermes dashboard plugin contract:
// - GET /api/dashboard/plugins[?profile=] lists dashboard plugins (name, label, description, icon, tab, entry, css,
//   has_api, source, version). Hidden tabs, overrides of built-in pages, and natively drawn plugins ("kanban") are excluded.
// - GET /api/dashboard/plugins/rescan[?profile=] re-reads plugin folders on the server.
// - GET /dashboard-plugins/[@<profile>/]<name>/<file> serves the bundle, CSS, and plugin assets.
// - Plugin APIs mount at /api/plugins/<name>/[?profile=]. A FastAPI bare 404 {"detail":"Not Found"} means the server
//   hasn't mounted the plugin's routes yet and needs a restart.

/// One Hermes dashboard plugin that adds a page (`dashboard/manifest.json` with a visible non-override `tab`).
public sealed record PluginDashboardPage(
    string Name,
    string Label,
    string Description,
    string Icon,
    string TabPath,
    string Entry,
    string? Css,
    bool HasApi,
    string Source,
    string Version)
{
    public string Id => Name;

    /// SF Symbol name parity with macOS (`PluginDashboardPage.symbol`).
    public string Symbol => SymbolForLucide(Icon);

    /// Segoe Fluent Icons glyph standing in for the Lucide icon on Windows.
    public string Glyph => GlyphForLucide(Icon);

    /// Plugins whose page Hermes HQ draws natively (Kanban has its own native tab with live updates and uploads).
    public static readonly IReadOnlySet<string> ShownNatively = new HashSet<string>(StringComparer.Ordinal) { "kanban" };

    /// The bundle/stylesheet/asset URL path: `/dashboard-plugins/[@<profile>/]<name>/<file>`.
    /// The default bot omits the `@profile` segment, matching the Hermes dashboard.
    public static string AssetPath(string name, string file, string profile)
    {
        var scope = string.IsNullOrEmpty(profile) || profile == "default" ? "" : $"@{Segment(profile)}/";
        var parts = file.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Where(s => s is not ("." or ".."))
            .Select(Segment);
        return $"/dashboard-plugins/{scope}{Segment(name)}/{string.Join("/", parts)}";
    }

    private static string Segment(string text) => Uri.EscapeDataString(text);

    /// Parses the JSON array returned by `GET /api/dashboard/plugins`, keeping openable pages only.
    public static List<PluginDashboardPage> Read(string json) => Read(J.Parse(json));

    public static List<PluginDashboardPage> Read(JsonNode? root)
    {
        if (root is not JsonArray rows) return [];
        var list = new List<PluginDashboardPage>();
        foreach (var row in rows)
        {
            if (ReadRow(row) is { } page) list.Add(page);
        }
        return list;
    }

    public static PluginDashboardPage? ReadRow(JsonNode? row)
    {
        if (row.Text("name") is not { } name || row.Text("entry") is not { } entry) return null;
        if (ShownNatively.Contains(name)) return null;
        var tab = row.Obj("tab");
        if (tab == null) return null;
        if (tab.Bool("hidden") == true) return null;
        var overrideNode = tab.Get("override");
        if (overrideNode != null && overrideNode.GetValueKind() != JsonValueKind.Null && tab.Bool("override") != false)
            return null;
        if (tab.Text("path") is not { } path) return null;

        return new PluginDashboardPage(
            Name: name,
            Label: row.Text("label") ?? DisplayName.Title(name),
            Description: row.Str("description") ?? "",
            Icon: row.Text("icon") ?? "",
            TabPath: path.StartsWith('/') ? path : "/" + path,
            Entry: entry,
            Css: row.Text("css"),
            HasApi: row.Bool("has_api") ?? false,
            Source: row.Text("source") ?? "",
            Version: row.Str("version") ?? "");
    }

    private static string NormalizeIconKey(string icon) =>
        icon.ToLowerInvariant().Replace("-", "", StringComparison.Ordinal).Replace("_", "", StringComparison.Ordinal);

    private static readonly IReadOnlyDictionary<string, string> LucideSymbols = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["database"] = "cylinder.split.1x2", ["brain"] = "brain", ["book"] = "book", ["bookopen"] = "book", ["library"] = "books.vertical",
        ["filetext"] = "doc.text", ["file"] = "doc", ["folder"] = "folder", ["notebook"] = "book.closed", ["notebookpen"] = "book.closed",
        ["barchart"] = "chart.bar", ["barchart3"] = "chart.bar", ["chartbar"] = "chart.bar", ["chartcolumn"] = "chart.bar",
        ["linechart"] = "chart.xyaxis.line", ["chartline"] = "chart.xyaxis.line", ["piechart"] = "chart.pie", ["activity"] = "waveform.path.ecg",
        ["gauge"] = "gauge.with.dots.needle.33percent", ["trophy"] = "trophy", ["award"] = "rosette", ["star"] = "star",
        ["globe"] = "globe", ["network"] = "point.3.connected.trianglepath.dotted", ["share2"] = "point.3.connected.trianglepath.dotted",
        ["calendar"] = "calendar", ["clock"] = "clock", ["history"] = "clock.arrow.circlepath", ["timer"] = "timer",
        ["kanban"] = "rectangle.split.3x1", ["layoutdashboard"] = "square.grid.2x2", ["layoutgrid"] = "square.grid.2x2",
        ["listtodo"] = "checklist", ["list"] = "list.bullet", ["checksquare"] = "checkmark.square",
        ["search"] = "magnifyingglass", ["settings"] = "gearshape", ["wrench"] = "wrench.and.screwdriver", ["terminal"] = "terminal",
        ["code"] = "chevron.left.forwardslash.chevron.right", ["bot"] = "cpu", ["cpu"] = "cpu", ["sparkles"] = "sparkles",
        ["messagesquare"] = "bubble.left", ["messagecircle"] = "bubble.left", ["mail"] = "envelope", ["users"] = "person.2",
        ["user"] = "person", ["image"] = "photo", ["camera"] = "camera", ["music"] = "music.note", ["mic"] = "mic",
        ["shield"] = "shield", ["lock"] = "lock", ["key"] = "key", ["smartphone"] = "iphone", ["monitor"] = "display",
        ["map"] = "map", ["compass"] = "safari", ["zap"] = "bolt", ["flame"] = "flame", ["heart"] = "heart", ["dollarsign"] = "dollarsign.circle",
        ["wallet"] = "wallet.bifold", ["package"] = "shippingbox", ["puzzle"] = "puzzlepiece.extension", ["layers"] = "square.3.layers.3d",
    };

    private static readonly IReadOnlyDictionary<string, string> LucideGlyphs = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["database"] = "\uEE94", ["brain"] = "\uE8F1", ["book"] = "\uE82D", ["bookopen"] = "\uE82D", ["library"] = "\uE8F1",
        ["filetext"] = "\uE8A5", ["file"] = "\uE7C3", ["folder"] = "\uE8B7", ["notebook"] = "\uE82D", ["notebookpen"] = "\uE70F",
        ["barchart"] = "\uE9D2", ["barchart3"] = "\uE9D2", ["chartbar"] = "\uE9D2", ["chartcolumn"] = "\uE9D2",
        ["linechart"] = "\uE9D9", ["chartline"] = "\uE9D9", ["piechart"] = "\uEB05", ["activity"] = "\uE9D9",
        ["gauge"] = "\uEC4A", ["trophy"] = "\uE734", ["award"] = "\uE734", ["star"] = "\uE734",
        ["globe"] = "\uE774", ["network"] = "\uE968", ["share2"] = "\uE72D",
        ["calendar"] = "\uE787", ["clock"] = "\uE823", ["history"] = "\uE81C", ["timer"] = "\uE916",
        ["kanban"] = "\uF0E2", ["layoutdashboard"] = "\uF0E2", ["layoutgrid"] = "\uF0E2",
        ["listtodo"] = "\uE762", ["list"] = "\uE8FD", ["checksquare"] = "\uE73A",
        ["search"] = "\uE721", ["settings"] = "\uE713", ["wrench"] = "\uE90F", ["terminal"] = "\uE756",
        ["code"] = "\uE943", ["bot"] = "\uE99A", ["cpu"] = "\uE950", ["sparkles"] = "\uE945",
        ["messagesquare"] = "\uE8BD", ["messagecircle"] = "\uE8BD", ["mail"] = "\uE715", ["users"] = "\uE716",
        ["user"] = "\uE77B", ["image"] = "\uEB9F", ["camera"] = "\uE722", ["music"] = "\uE8D6", ["mic"] = "\uE720",
        ["shield"] = "\uEA18", ["lock"] = "\uE72E", ["key"] = "\uE8D7", ["smartphone"] = "\uE8EA", ["monitor"] = "\uE7F4",
        ["map"] = "\uE707", ["compass"] = "\uE707", ["zap"] = "\uE945", ["flame"] = "\uE945", ["heart"] = "\uEB51",
        ["dollarsign"] = "\uE8C7", ["wallet"] = "\uE8C7", ["package"] = "\uE7B8", ["puzzle"] = "\uEA86", ["layers"] = "\uE81E",
    };

    /// SF Symbol name for a Lucide icon name (defaults to `square.grid.2x2`).
    public static string SymbolForLucide(string icon) =>
        LucideSymbols.TryGetValue(NormalizeIconKey(icon), out var symbol) ? symbol : "square.grid.2x2";

    /// Segoe Fluent Icons glyph for a Lucide icon name (defaults to grid `\uF0E2`).
    public static string GlyphForLucide(string icon) =>
        LucideGlyphs.TryGetValue(NormalizeIconKey(icon), out var glyph) ? glyph : "\uF0E2";
}

/// Extension matching `PluginCatalogEntry.addsDashboardPage` (`PluginPagesSection.swift`).
public static class PluginDashboardCatalogExtensions
{
    private static readonly string[] DashboardPhrases =
    [
        "dashboard tab", "dashboard page", "dashboard-only", "dashboard only", "dashboard plugin",
        "dashboard and desktop plugin", "from the hermes dashboard", "for the hermes dashboard",
        "in the hermes dashboard", "hermes dashboard and desktop",
    ];

    public static bool AddsDashboardPage(this PluginCatalogEntry entry)
    {
        var words = entry.Description.ToLowerInvariant();
        return DashboardPhrases.Any(p => words.Contains(p, StringComparison.Ordinal));
    }
}

/// Pure bridge validation, C5 percent-decoded traversal protection, FastAPI 404 detection, theme CSS variables,
/// and sandboxed host HTML construction (`DashboardPages.swift` + `PluginWebPage.swift` + `PluginPageTheme.swift`).
public static class PluginPageBridge
{
    /// Virtual origin used by the WebView2 host for plugin pages (never resolves on the network).
    public const string VirtualHost = "hqplugin.invalid";
    public const string VirtualOrigin = "https://hqplugin.invalid";

    public static readonly IReadOnlySet<string> Methods = new HashSet<string>(StringComparer.Ordinal)
    {
        "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD",
    };

    /// Validates a JS `fetchJSON`/`authedFetch` path strictly under `/api/plugins/<plugin>/` (or exact `/api/plugins/<plugin>`),
    /// rejecting dot segments (raw or percent-encoded), backslashes, control/NUL bytes, scheme prefixes, and other plugins.
    /// Appends `?profile=<profile>` for non-default bots unless the request already specifies a `profile` query parameter.
    public static string? AllowedPath(string raw, string plugin, string profile)
    {
        if (string.IsNullOrEmpty(raw) || string.IsNullOrEmpty(plugin)) return null;
        if (!IsSafeSegmentName(plugin)) return null;
        if (!raw.StartsWith('/') || raw.StartsWith("//", StringComparison.Ordinal) || raw.Length >= 8192) return null;
        if (HasForbiddenRawChars(raw)) return null;

        // Strip fragment if any, then split path and query without normalizing dot segments.
        var hash = raw.IndexOf('#');
        var noFrag = hash >= 0 ? raw[..hash] : raw;
        var qIdx = noFrag.IndexOf('?');
        var rawPath = qIdx >= 0 ? noFrag[..qIdx] : noFrag;
        var rawQuery = qIdx >= 0 ? noFrag[(qIdx + 1)..] : "";

        if (rawPath.Length == 0 || !rawPath.StartsWith('/') || rawPath.StartsWith("//", StringComparison.Ordinal)) return null;
        if (HasDotSegment(rawPath)) return null;

        var decodedPath = TryPercentDecode(rawPath);
        if (decodedPath == null) return null;
        if (HasForbiddenDecodedChars(decodedPath)) return null;
        if (decodedPath.StartsWith("//", StringComparison.Ordinal) || decodedPath.Contains("://", StringComparison.Ordinal)) return null;
        if (HasDotSegment(decodedPath)) return null;

        var own = $"/api/plugins/{plugin}";
        if (decodedPath != own && !decodedPath.StartsWith(own + "/", StringComparison.Ordinal)) return null;

        // Confirm URI parsing agrees and stays strictly inside `/api/plugins/<plugin>`.
        if (!Uri.TryCreate("https://page.invalid" + noFrag, UriKind.Absolute, out var parsed)) return null;
        var parsedDecoded = TryPercentDecode(parsed.AbsolutePath);
        if (parsedDecoded == null || HasDotSegment(parsedDecoded)) return null;
        if (parsedDecoded != own && !parsedDecoded.StartsWith(own + "/", StringComparison.Ordinal)) return null;

        var query = rawQuery;
        var hasProfile = HasQueryParam(query, "profile");
        if (!hasProfile && !string.IsNullOrEmpty(profile) && profile != "default")
        {
            var item = "profile=" + EscapeProfileQueryValue(profile);
            query = string.IsNullOrEmpty(query) ? item : query + "&" + item;
        }
        return string.IsNullOrEmpty(query) ? rawPath : rawPath + "?" + query;
    }

    /// Validates a plugin asset request path strictly inside `/dashboard-plugins/[@<profile>/]<plugin>/`,
    /// rejecting percent-encoded traversal (`%2e%2e`, `%2E%2E`, `%2e%2e%2f`, trailing `/..`, `.`), backslashes (`%5c`),
    /// NUL/control bytes (`%00`), scheme prefixes, and prefix collisions (`PluginPageSchemeHandler.allowedAssetPath`, C5).
    public static string? AllowedAssetPath(string path, string plugin, string profile, string query = "")
    {
        if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(plugin)) return null;
        if (!IsSafeSegmentName(plugin)) return null;
        if (path.Contains('?') || path.Contains('#')) return null;
        var raw = path + query;
        if (!path.StartsWith('/') || path.StartsWith("//", StringComparison.Ordinal) || raw.Length >= 8192) return null;
        if (HasForbiddenRawChars(raw)) return null;

        var assets = PluginDashboardPage.AssetPath(plugin, "", profile);
        if (!path.StartsWith(assets, StringComparison.Ordinal)) return null;

        var decoded = TryPercentDecode(path);
        var decodedAssets = TryPercentDecode(assets);
        if (decoded == null || decodedAssets == null) return null;
        if (HasForbiddenDecodedChars(decoded)) return null;
        if (decoded.StartsWith("//", StringComparison.Ordinal) || decoded.Contains("://", StringComparison.Ordinal)) return null;
        if (!decoded.StartsWith(decodedAssets, StringComparison.Ordinal)) return null;
        if (HasDotSegment(path) || HasDotSegment(decoded)) return null;

        if (!Uri.TryCreate("https://page.invalid" + raw, UriKind.Absolute, out var uri)) return null;
        var normalizedPath = TryPercentDecode(uri.AbsolutePath);
        if (normalizedPath == null || !normalizedPath.StartsWith(decodedAssets, StringComparison.Ordinal) || HasDotSegment(normalizedPath))
            return null;

        return raw;
    }

    /// Detects a FastAPI bare 404 (`{"detail":"Not Found"}` or empty 404) meaning the plugin's routes aren't mounted yet
    /// and Hermes needs a restart, distinguishing it from a plugin's own 404 (e.g., `{"detail":"Subject not found"}`).
    public static bool RouteMissing(int status, string? body)
    {
        if (status != 404) return false;
        if (string.IsNullOrEmpty(body)) return true;
        var parsed = J.Parse(body);
        if (parsed == null) return false;
        return parsed.Text("detail") == "Not Found";
    }

    /// Plain-words HTTP failure message matching Swift `HTTPError.plainWords` for plugin bridge responses.
    public static string PlainHttpWords(int status) => status switch
    {
        401 or 403 => "Your session on this gateway ended. Sign in again.",
        404 => "Your gateway couldn’t find that.",
        408 => "Hermes took too long to answer. Try again.",
        429 => "Your gateway is busy right now. Wait a moment, then try again.",
        >= 500 => "Hermes had a problem answering that request. Try again.",
        _ => "Hermes couldn’t do that. Try again.",
    };

    /// MIME type for plugin asset extensions (`PluginPageSchemeHandler.type(of:)`).
    public static string ContentType(string path)
    {
        var ext = Path.GetExtension(path).ToLowerInvariant();
        return ext switch
        {
            ".js" or ".mjs" => "application/javascript",
            ".css" => "text/css",
            ".json" or ".map" => "application/json",
            ".svg" => "image/svg+xml",
            ".png" => "image/png",
            ".jpg" or ".jpeg" => "image/jpeg",
            ".gif" => "image/gif",
            ".webp" => "image/webp",
            ".woff2" => "font/woff2",
            ".woff" => "font/woff",
            ".ttf" => "font/ttf",
            ".html" => "text/html",
            _ => "application/octet-stream",
        };
    }

    /// Builds the `:root { --hq-*: ...; color-scheme: ...; }` stylesheet from resolved `ThemeTokens` (`PluginPageTheme.swift`).
    public static string BuildThemeCss(ThemeTokens tokens, ThemeState state, bool dark)
    {
        static string Css(Rgba c, double? alphaOverride = null)
        {
            var a = Math.Clamp(alphaOverride ?? c.A, 0, 1);
            return $"rgba({Rgba.Byte(c.R)},{Rgba.Byte(c.G)},{Rgba.Byte(c.B)},{a.ToString("0.000", CultureInfo.InvariantCulture)})";
        }

        var desktop = state.DesktopLook;
        var radius = desktop ? (int)Math.Round(state.ShapeRadius(ShapeRole.Sheet, 12), MidpointRounding.AwayFromZero) : 12;
        var segment = dark ? Css(tokens.Label, 0.2) : Css(tokens.Lifted);
        var glass = Css(tokens.GroupedCard, desktop ? 1.0 : 0.72);
        var glassEdge = dark ? "rgba(255,255,255,0.16)" : "rgba(0,0,0,0.08)";
        var cardBorder = desktop ? $"1px solid {Css(tokens.StrokePrimary)}" : "0 solid transparent";
        var scheme = dark ? "dark" : "light";

        var sb = new StringBuilder(":root{");
        (string Key, string Value)[] vars =
        [
            ("--hq-scheme", scheme),
            ("--hq-bg", Css(tokens.Grouped)),
            ("--hq-card", Css(tokens.GroupedCard)),
            ("--hq-label", Css(tokens.Label)),
            ("--hq-label2", Css(tokens.Label2)),
            ("--hq-label3", Css(tokens.Label3)),
            ("--hq-separator", Css(tokens.Separator)),
            ("--hq-tint", Css(tokens.Tint)),
            ("--hq-on-tint", Css(tokens.OnTint)),
            ("--hq-fill", Css(tokens.Fill3)),
            ("--hq-segment", segment),
            ("--hq-red", Css(tokens.Red)),
            ("--hq-orange", Css(tokens.Orange)),
            ("--hq-green", Css(tokens.Green)),
            ("--hq-glass", glass),
            ("--hq-glass-edge", glassEdge),
            ("--hq-radius", $"{radius}px"),
            ("--hq-card-border", cardBorder),
            ("--hq-page-pad", "20px"),
            ("--hq-body-size", "15px"),
            ("--hq-text-min", "0px"),
        ];
        foreach (var (k, v) in vars) sb.Append(k).Append(':').Append(v).Append(';');
        sb.Append("color-scheme:").Append(scheme).Append(";}");
        return sb.ToString();
    }

    /// Lightweight bridge shim so the verbatim `plugin-host.js` (written against WKWebView's
    /// `window.webkit.messageHandlers.hq` / `.hqNote`) talks transparently over WebView2's `window.chrome.webview`.
    public const string WebView2BridgeShimScript = """
        (function(){
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hq) return;
          if (!window.chrome || !window.chrome.webview) return;
          var pending = new Map();
          var nextId = 1;
          window.chrome.webview.addEventListener('message', function(ev) {
            var msg = ev.data;
            if (!msg || typeof msg !== 'object' || msg.__hqReply !== true) return;
            var entry = pending.get(msg.id);
            if (!entry) return;
            pending.delete(msg.id);
            if (msg.reject) entry.reject(new Error(msg.reject));
            else entry.resolve(msg.value);
          });
          window.webkit = window.webkit || {};
          window.webkit.messageHandlers = window.webkit.messageHandlers || {};
          window.webkit.messageHandlers.hq = {
            postMessage: function(payload) {
              return new Promise(function(resolve, reject) {
                var id = nextId++;
                pending.set(id, { resolve: resolve, reject: reject });
                window.chrome.webview.postMessage({ __hqChannel: 'hq', id: id, payload: payload });
              });
            }
          };
          window.webkit.messageHandlers.hqNote = {
            postMessage: function(payload) {
              window.chrome.webview.postMessage({ __hqChannel: 'hqNote', payload: payload });
            }
          };
        })();
        """;

    /// Builds the sandboxed host HTML shell injecting theme CSS variables, `plugin-host.css`, `tailwind.js`,
    /// WebView2 bridge shim, `plugin-host.js`, optional plugin CSS, and the plugin entry bundle (`PluginWebPage.swift`).
    public static string BuildHostHtml(
        PluginDashboardPage page,
        string profile,
        string themeCss,
        string hostCss,
        string? inlineTailwindJs = null,
        string? inlineHostJs = null)
    {
        var effectiveProfile = string.IsNullOrEmpty(profile) || profile == "default" ? "" : profile;
        var infoObj = new JsonObject
        {
            ["name"] = page.Name,
            ["label"] = page.Label,
            ["profile"] = effectiveProfile,
        };
        var infoJson = SafeScriptJson(infoObj.ToJsonString());
        var entry = PluginDashboardPage.AssetPath(page.Name, page.Entry, profile);
        var pluginCss = !string.IsNullOrEmpty(page.Css)
            ? $"<link rel=\"stylesheet\" href=\"{EscapeHtml(PluginDashboardPage.AssetPath(page.Name, page.Css, profile))}\">"
            : "";
        var tailwindTag = inlineTailwindJs != null
            ? $"<script>{SafeInlineScript(inlineTailwindJs)}</script>"
            : "<script src=\"/__hq/tailwind.js\"></script>";
        var hostJsTag = inlineHostJs != null
            ? $"<script>{SafeInlineScript(inlineHostJs)}</script>"
            : "<script src=\"/__hq/plugin-host.js\"></script>";

        return $$"""
            <!doctype html>
            <html lang="en"><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            <title>{{EscapeHtml(page.Label)}}</title>
            <style id="hq-vars">{{SafeStyleContent(themeCss)}}</style>
            <script>window.__HQ_PAGE__ = {{infoJson}};</script>
            <script>{{WebView2BridgeShimScript}}</script>
            {{tailwindTag}}
            <style type="text/tailwindcss">{{SafeStyleContent(hostCss)}}</style>
            {{pluginCss}}
            {{hostJsTag}}
            </head><body><div id="root"></div>
            <script src="{{EscapeHtml(entry)}}" data-hermes-profile="{{EscapeHtml(effectiveProfile)}}" onerror="window.__HQ_HOST__ && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hqNote.postMessage({kind:'state',state:'script-error',message:'The page\u2019s script didn\u2019t load.'})"></script>
            <script>window.__HQ_HOST__ && window.__HQ_HOST__.bundleRan();</script>
            </body></html>
            """;
    }

    public static string EscapeHtml(string text) =>
        text.Replace("&", "&amp;", StringComparison.Ordinal)
            .Replace("<", "&lt;", StringComparison.Ordinal)
            .Replace(">", "&gt;", StringComparison.Ordinal)
            .Replace("\"", "&quot;", StringComparison.Ordinal);

    private static string SafeScriptJson(string json) =>
        json.Replace("</", "<\\/", StringComparison.Ordinal)
            .Replace("\u2028", "\\u2028", StringComparison.Ordinal)
            .Replace("\u2029", "\\u2029", StringComparison.Ordinal);

    private static string SafeInlineScript(string script) =>
        script.Replace("</script", "<\\/script", StringComparison.OrdinalIgnoreCase);

    private static string SafeStyleContent(string css) =>
        css.Replace("</style", "<\\/style", StringComparison.OrdinalIgnoreCase);

    private static bool IsSafeSegmentName(string name)
    {
        if (name is "." or ".." || name.Length > 256) return false;
        foreach (var c in name)
        {
            if (c is '/' or '\\' or '?' or '#' || c < 0x20 || c == 0x7F) return false;
        }
        return true;
    }

    private static bool HasForbiddenRawChars(string text)
    {
        foreach (var c in text)
        {
            if (c == '\\' || c < 0x20 || c == 0x7F) return true;
        }
        return false;
    }

    private static bool HasForbiddenDecodedChars(string text)
    {
        foreach (var c in text)
        {
            if (c == '\\' || c < 0x20 || c == 0x7F) return true;
        }
        return false;
    }

    private static bool HasDotSegment(string path)
    {
        foreach (var segment in path.Split('/'))
        {
            if (segment is "." or "..") return true;
        }
        return false;
    }

    private static bool HasQueryParam(string rawQuery, string targetName)
    {
        if (string.IsNullOrEmpty(rawQuery)) return false;
        foreach (var part in rawQuery.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = part.IndexOf('=');
            var rawName = eq >= 0 ? part[..eq] : part;
            var name = TryPercentDecode(rawName.Replace('+', ' ')) ?? rawName;
            if (string.Equals(name, targetName, StringComparison.Ordinal)) return true;
        }
        return false;
    }

    private static string EscapeProfileQueryValue(string profile)
    {
        var sb = new StringBuilder(profile.Length);
        foreach (var b in Encoding.UTF8.GetBytes(profile))
        {
            if ((b is >= (byte)'A' and <= (byte)'Z')
                || (b is >= (byte)'a' and <= (byte)'z')
                || (b is >= (byte)'0' and <= (byte)'9')
                || b is (byte)'-' or (byte)'_' or (byte)'.')
            {
                sb.Append((char)b);
            }
            else
            {
                sb.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
            }
        }
        return sb.ToString();
    }

    /// Strict RFC 3986 percent-decoder (rejects truncated/non-hex `%` escapes and invalid UTF-8 sequences).
    private static string? TryPercentDecode(string text)
    {
        if (!text.Contains('%')) return text;
        var bytes = new List<byte>(text.Length);
        for (var i = 0; i < text.Length; i++)
        {
            var ch = text[i];
            if (ch == '%')
            {
                if (i + 2 >= text.Length) return null;
                var hi = HexVal(text[i + 1]);
                var lo = HexVal(text[i + 2]);
                if (hi < 0 || lo < 0) return null;
                bytes.Add((byte)((hi << 4) | lo));
                i += 2;
            }
            else
            {
                if (ch < 0x80) bytes.Add((byte)ch);
                else bytes.AddRange(Encoding.UTF8.GetBytes([ch]));
            }
        }
        try
        {
            return new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true).GetString(bytes.ToArray());
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    private static int HexVal(char c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'a' and <= 'f' => c - 'a' + 10,
        >= 'A' and <= 'F' => c - 'A' + 10,
        _ => -1,
    };
}

/// Prompt sent to the main bot when a plugin page's API routes aren't mounted yet (`PluginWebPage.swift`).
public static class PluginPageRestart
{
    public const string AppName = "Hermes HQ";

    public static string Title(string page) => $"Restart Hermes so {page} opens in {AppName}.";

    public static string Prompt(string label, string plugin, string bot) => $"""
        Please restart Hermes so the {plugin} plugin's page ({label}) works in {AppName}. It's installed and on for {bot}, but the server hasn't loaded its routes yet: /api/plugins/{plugin}/ answers 404. Do it yourself with your terminal tools; ask me only for what you can't do.

        Hermes loads a plugin's web routes only when its web server starts, so restart the server {AppName} connects to (hermes dashboard or hermes serve). Find how it runs first (whether a launchd, systemd or other service manages it), then restart it the same way, keeping its arguments and profile. Restarting ends this chat's connection for a moment, so tell me before you do it, and schedule the restart in the background to start about 15 seconds after your reply, so it survives this chat (for example nohup sh -c 'sleep 15; <restart command>' >/dev/null 2>&1 &). It must run exactly once: never schedule it with launchctl submit, a LaunchAgent, cron, a systemd timer or anything else that starts it again, because a restart that repeats keeps Hermes down and locks me out. Don't restart anything else.

        When you're done, tell me in a sentence what you did.
        """;
}

/// One discovered page and the visible bots that provide it (`PluginPagesMore.Listed`).
public sealed record PluginPageListed(PluginDashboardPage Page, IReadOnlyList<string> Profiles);

/// Cross-bot page merging and bounded discovery helpers (`PluginPagesMore.swift`).
public static class DashboardPagesMerge
{
    /// Minimum gap before a reconnect triggers another full discovery pass (10 minutes).
    public static readonly TimeSpan ReconnectGap = TimeSpan.FromMinutes(10);

    /// Maximum concurrent bot page reads so cold launch never fans out across every bot at once.
    public const int ReadWidth = 2;

    public static bool IsDue(DateTimeOffset? lastRead, DateTimeOffset now) =>
        lastRead is not { } at || now - at >= ReconnectGap;

    /// Merges per-bot page lists into one list sorted by label, keeping each page once with its bots in `bots` order.
    public static List<PluginPageListed> Merge(
        IReadOnlyDictionary<string, IReadOnlyList<PluginDashboardPage>> byBot,
        IReadOnlyList<string> bots)
    {
        var map = new Dictionary<string, (PluginDashboardPage Page, List<string> Profiles)>(StringComparer.Ordinal);
        foreach (var bot in bots)
        {
            if (!byBot.TryGetValue(bot, out var pages)) continue;
            foreach (var page in pages)
            {
                if (!map.TryGetValue(page.Name, out var entry))
                    map[page.Name] = entry = (page, []);
                if (!entry.Profiles.Contains(bot)) entry.Profiles.Add(bot);
            }
        }
        return [.. map.Values
            .OrderBy(e => e.Page.Label, StringComparer.CurrentCultureIgnoreCase)
            .Select(e => new PluginPageListed(e.Page, e.Profiles))];
    }

    /// Reads `profiles` with at most `width` concurrent requests, returning only profiles whose fetch succeeded.
    public static async Task<Dictionary<string, IReadOnlyList<PluginDashboardPage>>> ReadPagesAsync(
        IReadOnlyList<string> profiles,
        Func<string, Task<IReadOnlyList<PluginDashboardPage>?>> fetch,
        int width = ReadWidth,
        CancellationToken ct = default)
    {
        var results = new Dictionary<string, IReadOnlyList<PluginDashboardPage>>(StringComparer.Ordinal);
        if (profiles.Count == 0 || width <= 0) return results;
        using var gate = new SemaphoreSlim(width, width);
        var tasks = profiles.Select(async profile =>
        {
            await gate.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                if (ct.IsCancellationRequested) return (profile, (IReadOnlyList<PluginDashboardPage>?)null);
                var pages = await fetch(profile).ConfigureAwait(false);
                return (profile, pages);
            }
            finally
            {
                gate.Release();
            }
        }).ToList();

        foreach (var (profile, pages) in await Task.WhenAll(tasks).ConfigureAwait(false))
        {
            if (pages != null) results[profile] = pages;
        }
        return results;
    }
}

/// REST calls for Hermes dashboard plugin pages (`DashboardPagesAPI` in `DashboardPages.swift`).
public sealed class DashboardPagesApi(GatewaySession session)
{
    public GatewaySession Session { get; } = session;

    public static KeyValuePair<string, string>[] ProfileQuery(string? profile) =>
        string.IsNullOrEmpty(profile) || profile == "default" ? [] : [new("profile", profile)];

    public async Task<List<PluginDashboardPage>> ListAsync(string? profile = null, CancellationToken ct = default)
    {
        var answer = await Session.SendAsync(HttpMethod.Get, "/api/dashboard/plugins", ProfileQuery(profile), ct: ct).ConfigureAwait(false);
        if (!answer.Ok) throw GatewaySession.HttpError(answer);
        return PluginDashboardPage.Read(answer.Body);
    }

    /// Re-reads plugin folders on the server. Older servers have no rescan; errors are ignored.
    public async Task RescanAsync(string? profile = null, CancellationToken ct = default)
    {
        try
        {
            await Session.SendAsync(HttpMethod.Get, "/api/dashboard/plugins/rescan", ProfileQuery(profile), ct: ct).ConfigureAwait(false);
        }
        catch (GatewayException) { }
    }

    /// Lists pages, issuing one rescan when an enabled plugin in `installed` is missing and hasn't been rescanned yet.
    public async Task<List<PluginDashboardPage>> PagesAsync(
        string? profile,
        IReadOnlySet<string> installed,
        ISet<string> rescanned,
        CancellationToken ct = default)
    {
        var first = await ListAsync(profile, ct).ConfigureAwait(false);
        var listed = first.Select(p => p.Name).ToHashSet(StringComparer.Ordinal);
        var unseen = installed.Where(name => !listed.Contains(name) && !rescanned.Contains(name)).ToList();
        if (unseen.Count == 0) return first;
        foreach (var name in unseen) rescanned.Add(name);
        await RescanAsync(profile, ct).ConfigureAwait(false);
        try { return await ListAsync(profile, ct).ConfigureAwait(false); }
        catch (GatewayException) { return first; }
    }

    /// Fetches a validated plugin bundle, stylesheet, or asset over the authenticated gateway session.
    public Task<ByteAnswer> FetchAssetAsync(string assetPathWithQuery, TimeSpan? timeout = null, CancellationToken ct = default) =>
        Session.SendBytesAsync(HttpMethod.Get, assetPathWithQuery, null, null, "application/octet-stream",
            timeout ?? TimeSpan.FromSeconds(30), ct);

    /// Sends a validated plugin bridge request (`fetchJSON`/`authedFetch`) with the account's auth.
    public Task<ByteAnswer> FetchBridgeAsync(
        HttpMethod method,
        string allowedPathWithQuery,
        string? body = null,
        string contentType = "application/json",
        TimeSpan? timeout = null,
        CancellationToken ct = default)
    {
        var bytes = body != null ? Encoding.UTF8.GetBytes(body) : null;
        return Session.SendBytesAsync(method, allowedPathWithQuery, null, bytes, contentType,
            timeout ?? TimeSpan.FromSeconds(60), ct);
    }
}
