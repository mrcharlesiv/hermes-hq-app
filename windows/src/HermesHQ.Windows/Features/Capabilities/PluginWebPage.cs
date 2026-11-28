using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Capabilities;
using Hermes.Core.Net;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Web.WebView2.Core;
using Windows.System;

namespace HermesHQ.Features.Capabilities;

/// CSS variable generator for hosted plugin pages (`App/Capabilities/PluginPages/PluginPageTheme.swift`),
/// delegating to `PluginPageBridge.BuildThemeCss` against live `ThemeService` state.
public static class PluginPageTheme
{
    public static string CurrentCss() =>
        PluginPageBridge.BuildThemeCss(ThemeService.Tokens, ThemeService.State, ThemeService.Dark);
}

/// Hosts a Hermes dashboard plugin page inside WebView2 with authenticated bridge messaging, live theme updates,
/// 20-second startup watchdog, FastAPI bare-404 restart guidance, and per-bot profile switching
/// (`App/Capabilities/PluginPages/PluginWebPage.swift`).
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class PluginWebPage : Page, IKeyRefreshing
{
    private enum Phase { Loading, Ready, Failed, NeedsRestart }

    private static readonly TimeSpan WatchdogTimeout = TimeSpan.FromSeconds(20);
    private static readonly string AssetsDir = Path.Combine(AppContext.BaseDirectory, "Assets", "PluginHost");

    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    private readonly TextBlock _title = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly ComboBox _botPicker = new() { MinWidth = 150, Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
    private readonly Grid _webHost = new();
    private readonly Border _statusOverlay = new() { HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };
    private readonly Border _troubleBar = new()
    {
        Visibility = Visibility.Collapsed,
        CornerRadius = new CornerRadius(10),
        Padding = new Thickness(14, 10, 14, 10),
        Margin = new Thickness(16, 0, 16, 16),
        BorderThickness = new Thickness(1),
        VerticalAlignment = VerticalAlignment.Bottom,
    };

    private PluginPageTarget? _target;
    private WebView2? _web;
    private byte[]? _bundleBytes;
    private byte[]? _cssBytes;
    private Phase _phase = Phase.Loading;
    private string _failTitle = "";
    private string _failWords = "";
    private string? _troubleWords;
    private bool _askingRestart;
    private string? _askNote;
    private bool _suppressPicker;
    private CancellationTokenSource? _loadCts;
    private CancellationTokenSource? _watchdogCts;
    private bool _disposed;

    public PluginWebPage()
    {
        NavigationCacheMode = NavigationCacheMode.Disabled;
        AutomationProperties.SetAutomationId(this, "plugin-web-page");

        var backBtn = new Button
        {
            Content = Kit.Glyph(Kit.Back, 14),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(8, 6, 8, 6),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(backBtn, "Back to Capabilities");
        ToolTipService.SetToolTip(backBtn, "Back to Capabilities");
        backBtn.Click += (_, _) => Navigator.Open("capabilities");

        PageBar.Title(_title, "plugin-page");

        AutomationProperties.SetName(_botPicker, "Bot");
        AutomationProperties.SetAutomationId(_botPicker, "plugin-web-page.bot");
        _botPicker.SelectionChanged += OnBotPicked;

        var reloadBtn = new Button
        {
            Content = Kit.Glyph(Kit.Refresh, 14),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(8, 6, 8, 6),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(reloadBtn, "Reload");
        AutomationProperties.SetAutomationId(reloadBtn, "plugin-web-page.reload");
        ToolTipService.SetToolTip(reloadBtn, "Reload");
        reloadBtn.Click += (_, _) => Reload();

        var bar = new Grid { Padding = PageBar.Padding(10, 10), ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(backBtn);
        Grid.SetColumn(_title, 1);
        bar.Children.Add(_title);
        Grid.SetColumn(_botPicker, 2);
        bar.Children.Add(_botPicker);
        Grid.SetColumn(reloadBtn, 3);
        bar.Children.Add(reloadBtn);

        var body = new Grid();
        body.Children.Add(_webHost);
        body.Children.Add(_statusOverlay);
        body.Children.Add(_troubleBar);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(bar);
        Grid.SetRow(body, 1);
        root.Children.Add(body);
        Content = root;

        Loaded += (_, _) =>
        {
            ThemeService.Changed -= OnThemeChanged;
            ThemeService.Changed += OnThemeChanged;
            ApplyNativeGround();
        };
        Unloaded += (_, _) => Cleanup();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _disposed = false;
        var arg = (e.Parameter as PlaceArgs)?.Argument;
        _target = PluginPagesService.ResolveTarget(arg);
        if (_target == null)
        {
            _title.Text = "Plugin Page";
            SetPhase(Phase.Failed, "Couldn’t Open Plugin Page", "No plugin page was specified.");
            return;
        }
        ConfigureChrome(_target);
        Reload();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        Cleanup();
    }

    public void KeyRefresh() => Reload();

    private void ConfigureChrome(PluginPageTarget target)
    {
        _title.Text = target.Page.Label;
        AutomationProperties.SetName(this, target.Page.Label);

        _suppressPicker = true;
        _botPicker.Items.Clear();
        if (target.OtherBots.Count > 1)
        {
            foreach (var (_, name) in target.OtherBots) _botPicker.Items.Add(name);
            var idx = -1;
            for (var i = 0; i < target.OtherBots.Count; i++)
            {
                if (target.OtherBots[i].Profile == target.Profile) { idx = i; break; }
            }
            _botPicker.SelectedIndex = idx >= 0 ? idx : 0;
            _botPicker.Visibility = Visibility.Visible;
        }
        else
        {
            _botPicker.Visibility = Visibility.Collapsed;
        }
        _suppressPicker = false;
    }

    private void OnBotPicked(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressPicker || _target == null) return;
        var idx = _botPicker.SelectedIndex;
        if (idx < 0 || idx >= _target.OtherBots.Count) return;
        var chosen = _target.OtherBots[idx];
        if (chosen.Profile == _target.Profile) return;
        var nextPage = PluginPagesService.PageFor(_target.Page.Name, chosen.Profile) ?? _target.Page;
        _target = _target with { Page = nextPage, Profile = chosen.Profile, BotName = chosen.Name };
        AppLog.Note("plugin-pages", $"switched {_target.Page.Name} to another bot");
        Reload();
    }

    private void Reload()
    {
        if (_disposed || _target == null) return;
        _loadCts?.Cancel();
        _watchdogCts?.Cancel();
        NoteTrouble(null);
        _askNote = null;
        SetPhase(Phase.Loading);

        var target = _target;
        var client = AppState.Client;
        if (client == null)
        {
            SetPhase(Phase.Failed, $"Couldn’t Open {target.Page.Label}", "Sign in to your gateway to open this page.");
            return;
        }

        var cts = new CancellationTokenSource();
        _loadCts = cts;
        var api = new DashboardPagesApi(client.Session);

        _ = LoadBundleAsync(target, api, cts.Token);
    }

    private async Task LoadBundleAsync(PluginPageTarget target, DashboardPagesApi api, CancellationToken ct)
    {
        try
        {
            var entryPath = PluginDashboardPage.AssetPath(target.Page.Name, target.Page.Entry, target.Profile);
            var entryAnswer = await api.FetchAssetAsync(entryPath, TimeSpan.FromSeconds(30), ct);
            if (!entryAnswer.Ok)
            {
                if (ct.IsCancellationRequested || _disposed) return;
                if (entryAnswer.Status == 404)
                {
                    SetPhase(Phase.Failed, $"Couldn’t Open {target.Page.Label}",
                        $"Hermes didn’t send this page’s files. Check that the plugin is on for {target.BotName} in Plugins. If it was just installed, Hermes may need a restart first.");
                }
                else
                {
                    SetPhase(Phase.Failed, $"Couldn’t Open {target.Page.Label}", PluginPageBridge.PlainHttpWords(entryAnswer.Status));
                }
                return;
            }

            byte[]? cssBytes = null;
            if (!string.IsNullOrEmpty(target.Page.Css))
            {
                try
                {
                    var cssPath = PluginDashboardPage.AssetPath(target.Page.Name, target.Page.Css, target.Profile);
                    var cssAnswer = await api.FetchAssetAsync(cssPath, TimeSpan.FromSeconds(20), ct);
                    if (cssAnswer.Ok) cssBytes = cssAnswer.Body;
                }
                catch (Exception) { /* optional stylesheet */ }
            }

            if (ct.IsCancellationRequested || _disposed) return;
            _bundleBytes = entryAnswer.Body;
            _cssBytes = cssBytes;
            await ShowWebAsync(target, api, ct);
        }
        catch (OperationCanceledException) { }
        catch (GatewayException ex)
        {
            if (ct.IsCancellationRequested || _disposed) return;
            SetPhase(Phase.Failed, $"Couldn’t Open {target.Page.Label}", CapabilitiesWords.Detail(ex));
        }
        catch (Exception ex)
        {
            if (ct.IsCancellationRequested || _disposed) return;
            AppLog.Note("plugin-pages", $"{target.Page.Name} load error: {ex.GetType().Name}");
            SetPhase(Phase.Failed, $"Couldn’t Open {target.Page.Label}", "Hermes didn’t answer.");
        }
    }

    private async Task ShowWebAsync(PluginPageTarget target, DashboardPagesApi api, CancellationToken ct)
    {
        DisposeWeb();
        var web = new WebView2
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            DefaultBackgroundColor = ThemeService.ToColor(ThemeService.Tokens.Grouped),
        };
        AutomationProperties.SetAutomationId(web, "plugin-web-page.web");
        _web = web;
        _webHost.Children.Add(web);

        try
        {
            var env = await WebViewEnv.GetAsync();
            await web.EnsureCoreWebView2Async(env);
        }
        catch (Exception ex)
        {
            if (ct.IsCancellationRequested || _disposed) return;
            AppLog.Note("plugin-pages", $"WebView2 init failed: {ex.GetType().Name}");
            SetPhase(Phase.Failed, $"Couldn’t Open {target.Page.Label}", "WebView2 isn’t available on this PC.");
            return;
        }

        if (ct.IsCancellationRequested || _disposed || !ReferenceEquals(_web, web)) return;

        var core = web.CoreWebView2;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        ApplyPreferredColorScheme(core);

        core.AddWebResourceRequestedFilter($"{PluginPageBridge.VirtualOrigin}/*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += (sender, args) => HandleResourceRequest(sender, args, target, api);
        core.WebMessageReceived += (_, args) => HandleWebMessage(core, args, target, api);
        core.NavigationStarting += (_, args) => HandleNavigationStarting(args);
        core.NewWindowRequested += (_, args) => HandleNewWindow(args);
        core.ProcessFailed += (_, _) =>
        {
            AppLog.Note("plugin-pages", $"{target.Page.Name} web process terminated; reloading");
            _ui.TryEnqueue(Reload);
        };

        var tabPath = PageUrlPath(target.Page);
        core.Navigate($"{PluginPageBridge.VirtualOrigin}{tabPath}");
        StartWatchdog(target);
    }

    private void StartWatchdog(PluginPageTarget target)
    {
        _watchdogCts?.Cancel();
        var cts = new CancellationTokenSource();
        _watchdogCts = cts;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(WatchdogTimeout, cts.Token).ConfigureAwait(false);
                if (cts.IsCancellationRequested || _disposed) return;
                _ui.TryEnqueue(() =>
                {
                    if (_disposed || _phase != Phase.Loading || _target?.Page.Name != target.Page.Name) return;
                    AppLog.Note("plugin-pages", $"{target.Page.Name} never reported ready within 20 s");
                    SetPhase(Phase.Failed, $"{target.Page.Label} Didn’t Start", "Its page took too long to load. Try again.");
                });
            }
            catch (OperationCanceledException) { }
        }, cts.Token);
    }

    private void HandleResourceRequest(
        CoreWebView2 core,
        CoreWebView2WebResourceRequestedEventArgs args,
        PluginPageTarget target,
        DashboardPagesApi api)
    {
        // Extract raw path/query before Uri dot-segment normalization so percent-encoded traversal payloads
        // (`%2e%2e`, `..`) reach `PluginPageBridge.AllowedAssetPath` / `AllowedPath` intact (C5).
        var reqUri = args.Request.Uri;
        if (string.IsNullOrEmpty(reqUri)
            || !reqUri.StartsWith(PluginPageBridge.VirtualOrigin, StringComparison.OrdinalIgnoreCase)
            || reqUri.Length <= PluginPageBridge.VirtualOrigin.Length
            || reqUri[PluginPageBridge.VirtualOrigin.Length] != '/')
            return;

        var tail = reqUri[PluginPageBridge.VirtualOrigin.Length..];
        var hashIdx = tail.IndexOf('#');
        if (hashIdx >= 0) tail = tail[..hashIdx];
        var qIdx = tail.IndexOf('?');
        var rawPath = qIdx >= 0 ? tail[..qIdx] : tail;
        var rawQuery = qIdx >= 0 ? tail[qIdx..] : "";
        var page = target.Page;
        var tabPath = PageUrlPath(page);
        var entryPath = PluginDashboardPage.AssetPath(page.Name, page.Entry, target.Profile);
        var cssPath = !string.IsNullOrEmpty(page.Css)
            ? PluginDashboardPage.AssetPath(page.Name, page.Css, target.Profile)
            : null;

        if (rawPath == "/__hq/plugin-host.js")
        {
            RespondBytes(core, args, ReadHostAsset("plugin-host.js"), "application/javascript");
            return;
        }
        if (rawPath == "/__hq/tailwind.js")
        {
            RespondBytes(core, args, ReadHostAsset("tailwind.js"), "application/javascript");
            return;
        }
        if (rawPath == tabPath || rawPath == "/" || rawPath == $"/{page.Name}")
        {
            var hostCss = ReadHostAssetText("plugin-host.css");
            var html = PluginPageBridge.BuildHostHtml(page, target.Profile, PluginPageTheme.CurrentCss(), hostCss);
            RespondBytes(core, args, Encoding.UTF8.GetBytes(html), "text/html; charset=utf-8");
            return;
        }
        if (rawPath == entryPath)
        {
            RespondBytes(core, args, _bundleBytes, "application/javascript");
            return;
        }
        if (cssPath != null && rawPath == cssPath && _cssBytes != null)
        {
            RespondBytes(core, args, _cssBytes, "text/css");
            return;
        }

        // Validate sub-assets strictly inside `/dashboard-plugins/[@<profile>/]<plugin>/` (C5 guard),
        // or GET routes strictly inside `/api/plugins/<plugin>/` (for images, etc.).
        string? remote = PluginPageBridge.AllowedAssetPath(rawPath, page.Name, target.Profile, rawQuery);
        if (remote == null && string.Equals(args.Request.Method, "GET", StringComparison.OrdinalIgnoreCase))
            remote = PluginPageBridge.AllowedPath(rawPath + rawQuery, page.Name, target.Profile);

        if (remote == null)
        {
            RespondStatus(core, args, 404, "Not Found");
            return;
        }

        var deferral = args.GetDeferral();
        var mime = PluginPageBridge.ContentType(rawPath);
        _ = FetchDeferredResourceAsync(core, args, deferral, api, remote, mime);
    }

    private async Task FetchDeferredResourceAsync(
        CoreWebView2 core,
        CoreWebView2WebResourceRequestedEventArgs args,
        Windows.Foundation.Deferral deferral,
        DashboardPagesApi api,
        string remote,
        string mime)
    {
        try
        {
            var answer = await api.FetchAssetAsync(remote, TimeSpan.FromSeconds(30));
            _ui.TryEnqueue(() =>
            {
                try
                {
                    if (answer.Ok) RespondBytes(core, args, answer.Body, mime);
                    else RespondStatus(core, args, answer.Status, "Error");
                }
                finally { deferral.Complete(); }
            });
        }
        catch (Exception)
        {
            _ui.TryEnqueue(() =>
            {
                try { RespondStatus(core, args, 502, "Bad Gateway"); }
                finally { deferral.Complete(); }
            });
        }
    }

    private static void RespondBytes(CoreWebView2 core, CoreWebView2WebResourceRequestedEventArgs args, byte[]? bytes, string contentType)
    {
        if (bytes == null)
        {
            RespondStatus(core, args, 404, "Not Found");
            return;
        }
        var stream = new MemoryStream(bytes, writable: false).AsRandomAccessStream();
        var headers = $"Content-Type: {contentType}\r\nCache-Control: no-store";
        args.Response = core.Environment.CreateWebResourceResponse(stream, 200, "OK", headers);
    }

    private static void RespondStatus(CoreWebView2 core, CoreWebView2WebResourceRequestedEventArgs args, int status, string reason)
    {
        var stream = new MemoryStream([], writable: false).AsRandomAccessStream();
        args.Response = core.Environment.CreateWebResourceResponse(stream, status, reason, "Cache-Control: no-store");
    }

    private void HandleWebMessage(CoreWebView2 core, CoreWebView2WebMessageReceivedEventArgs args, PluginPageTarget target, DashboardPagesApi api)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(args.WebMessageAsJson); }
        catch (JsonException) { return; }
        if (root is not JsonObject envelope) return;

        var channel = envelope.Str("__hqChannel");
        var payload = envelope.Obj("payload");
        if (channel == "hqNote")
        {
            HandleStateNote(payload, target);
            return;
        }
        if (channel != "hq") return;

        var id = envelope.Int("id") ?? 0;
        if (payload == null || payload.Str("kind") != "fetch" || payload.Str("path") is not { } rawPath)
        {
            PostReply(core, id, new JsonObject { ["status"] = 400, ["body"] = "{\"detail\":\"Bad request\"}" });
            return;
        }

        var method = (payload.Str("method") ?? "GET").ToUpperInvariant();
        var allowed = PluginPageBridge.Methods.Contains(method)
            ? PluginPageBridge.AllowedPath(rawPath, target.Page.Name, target.Profile)
            : null;
        if (allowed == null)
        {
            AppLog.Note("plugin-pages", $"{target.Page.Name} asked for a route outside its own: refused");
            PostReply(core, id, new JsonObject
            {
                ["status"] = 403,
                ["body"] = "{\"detail\":\"Hermes HQ lets a plugin page call only its own plugin\u2019s routes.\"}",
            });
            return;
        }

        var bodyText = payload.Str("body");
        var contentType = payload.Obj("headers")?.FirstOrDefault(p => p.Key.Equals("content-type", StringComparison.OrdinalIgnoreCase)).Value?.ToString()
            ?? "application/json";
        _ = ExecuteBridgeFetchAsync(core, id, new HttpMethod(method), allowed, bodyText, contentType, api);
    }

    private async Task ExecuteBridgeFetchAsync(
        CoreWebView2 core,
        long id,
        HttpMethod method,
        string allowedPath,
        string? bodyText,
        string contentType,
        DashboardPagesApi api)
    {
        try
        {
            var answer = await api.FetchBridgeAsync(method, allowedPath, bodyText, contentType, TimeSpan.FromSeconds(60));
            var text = answer.Body.Length > 0 ? Encoding.UTF8.GetString(answer.Body) : "";
            if (answer.Ok)
            {
                _ui.TryEnqueue(() =>
                {
                    if (_disposed) return;
                    NoteTrouble(null);
                    PostReply(core, id, new JsonObject { ["status"] = answer.Status, ["body"] = text });
                });
                return;
            }

            var words = PluginPageBridge.PlainHttpWords(answer.Status);
            _ui.TryEnqueue(() =>
            {
                if (_disposed) return;
                if (PluginPageBridge.RouteMissing(answer.Status, text))
                    SetPhase(Phase.NeedsRestart);
                else if (answer.Status >= 500 || answer.Status is 408 or 429)
                    NoteTrouble(words);
                PostReply(core, id, new JsonObject { ["status"] = answer.Status, ["body"] = text, ["words"] = words });
            });
        }
        catch (Exception ex)
        {
            var words = ex is GatewayException ge ? CapabilitiesWords.Detail(ge) : "Hermes HQ couldn’t reach Hermes.";
            _ui.TryEnqueue(() =>
            {
                if (_disposed) return;
                NoteTrouble(words);
                PostReply(core, id, new JsonObject { ["status"] = 0, ["error"] = words });
            });
        }
    }

    private void PostReply(CoreWebView2 core, long id, JsonObject value)
    {
        if (_disposed) return;
        try
        {
            var msg = new JsonObject
            {
                ["__hqReply"] = true,
                ["id"] = id,
                ["value"] = value,
            };
            core.PostWebMessageAsJson(msg.ToJsonString());
        }
        catch (Exception) { /* webview closed */ }
    }

    private void HandleStateNote(JsonObject? payload, PluginPageTarget target)
    {
        if (payload == null || payload.Str("kind") != "state") return;
        var state = payload.Str("state");
        var detail = payload.Str("message") is { Length: > 0 } m ? (m.Length > 300 ? m[..300] : m) : null;

        switch (state)
        {
            case "ready":
                if (_phase != Phase.Loading) return;
                _watchdogCts?.Cancel();
                SetPhase(Phase.Ready);
                break;
            case "unregistered":
                if (_phase != Phase.Loading) return;
                _watchdogCts?.Cancel();
                AppLog.Note("plugin-pages", $"{target.Page.Name} bundle ran but never registered");
                SetPhase(Phase.Failed, $"{target.Page.Label} Didn’t Start",
                    "Its page loaded but never showed itself. It may need a newer version of Hermes HQ, or of the plugin.");
                break;
            case "script-error":
                if (_phase != Phase.Loading) return;
                _watchdogCts?.Cancel();
                AppLog.Note("plugin-pages", $"{target.Page.Name} script error");
                SetPhase(Phase.Failed, $"{target.Page.Label} Didn’t Start",
                    "Its page hit an error while loading" + (detail != null ? $": {detail}" : "."));
                break;
            case "crashed":
                _watchdogCts?.Cancel();
                AppLog.Note("plugin-pages", $"{target.Page.Name} crashed");
                SetPhase(Phase.Failed, $"{target.Page.Label} Stopped",
                    "Its page hit an error" + (detail != null ? $": {detail}" : "."));
                break;
        }
    }

    private static void HandleNavigationStarting(CoreWebView2NavigationStartingEventArgs args)
    {
        if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri))
        {
            args.Cancel = true;
            return;
        }
        if (string.Equals(uri.Host, PluginPageBridge.VirtualHost, StringComparison.OrdinalIgnoreCase)
            && uri.Scheme == "https")
            return;

        args.Cancel = true;
        if (args.IsUserInitiated && uri.Scheme is "http" or "https" or "mailto")
            _ = Launcher.LaunchUriAsync(uri);
    }

    private static void HandleNewWindow(CoreWebView2NewWindowRequestedEventArgs args)
    {
        args.Handled = true;
        if (Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" or "mailto")
            _ = Launcher.LaunchUriAsync(uri);
    }

    private void OnThemeChanged()
    {
        if (_disposed || AppShutdown.Stopping) return;
        _ui.TryEnqueue(() =>
        {
            if (_disposed || AppShutdown.Stopping) return;
            ApplyNativeGround();
            if (_web?.CoreWebView2 is { } core)
            {
                ApplyPreferredColorScheme(core);
                var cssJson = JsonSerializer.Serialize(PluginPageTheme.CurrentCss());
                _ = core.ExecuteScriptAsync($"window.__HQ_HOST__ && window.__HQ_HOST__.theme({cssJson})");
            }
        });
    }

    private void ApplyNativeGround()
    {
        var bg = Kit.Brush("HQGroupedBrush");
        Background = bg;
        _statusOverlay.Background = bg;
        if (_web != null) _web.DefaultBackgroundColor = ThemeService.ToColor(ThemeService.Tokens.Grouped);
        _troubleBar.Background = Kit.Brush("CardBackgroundFillColorDefaultBrush");
        _troubleBar.BorderBrush = Kit.Brush("CardStrokeColorDefaultBrush");
    }

    private static void ApplyPreferredColorScheme(CoreWebView2 core)
    {
        try
        {
            if (core.Profile is { } profile)
                profile.PreferredColorScheme = ThemeService.Dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
        }
        catch (Exception) { }
    }

    private void SetPhase(Phase next, string title = "", string words = "")
    {
        _phase = next;
        _failTitle = title;
        _failWords = words;
        RenderStatusOverlay();
    }

    private void RenderStatusOverlay()
    {
        UiTree.DeactivateProgressRings(_statusOverlay);
        if (_phase == Phase.Ready)
        {
            _statusOverlay.Child = null;
            _statusOverlay.Visibility = Visibility.Collapsed;
            _troubleBar.Visibility = _troubleWords != null ? Visibility.Visible : Visibility.Collapsed;
            return;
        }

        _troubleBar.Visibility = Visibility.Collapsed;
        _statusOverlay.Visibility = Visibility.Visible;
        _statusOverlay.Background = Kit.Brush("HQGroupedBrush");

        var label = _target?.Page.Label ?? "Plugin";
        switch (_phase)
        {
            case Phase.Loading:
            {
                var panel = new StackPanel
                {
                    Spacing = 12,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                panel.Children.Add(new ProgressRing { IsActive = true, Width = 28, Height = 28, HorizontalAlignment = HorizontalAlignment.Center });
                panel.Children.Add(Kit.Text($"Opening {label}…", 14, secondary: true, wrap: false));
                AutomationProperties.SetAutomationId(panel, "plugin-web-page.loading");
                _statusOverlay.Child = panel;
                break;
            }
            case Phase.Failed:
            {
                var retry = Kit.Button("Try Again", Reload, accent: true);
                AutomationProperties.SetAutomationId(retry, "plugin-web-page.retry");
                _statusOverlay.Child = BuildMessageCard(Kit.Warning, _failTitle, _failWords, [retry], "plugin-web-page.failed");
                break;
            }
            case Phase.NeedsRestart:
            {
                var actions = new List<UIElement>();
                if (CanAskRestart())
                {
                    var ask = Kit.Button(_askingRestart ? "Asking…" : "Ask Main Bot to Restart", () => _ = AskMainBotToRestartAsync(),
                        accent: true, enabled: !_askingRestart);
                    AutomationProperties.SetAutomationId(ask, "plugin-web-page.ask-restart");
                    actions.Add(ask);
                }
                var retry = Kit.Button("Try Again", Reload);
                AutomationProperties.SetAutomationId(retry, "plugin-web-page.retry");
                actions.Add(retry);
                if (!string.IsNullOrEmpty(_askNote))
                {
                    var note = Kit.Text(_askNote, 12, color: Kit.Critical);
                    note.HorizontalTextAlignment = TextAlignment.Center;
                    actions.Add(note);
                }
                _statusOverlay.Child = BuildMessageCard(
                    Kit.Refresh,
                    "Restart Hermes to Finish",
                    $"{label} is installed, but Hermes loads a plugin’s web routes only when its web server starts. Restart Hermes once and this page will work.",
                    actions,
                    "plugin-web-page.restart");
                break;
            }
        }
    }

    private static UIElement BuildMessageCard(string glyph, string title, string words, IEnumerable<UIElement> actions, string automationId)
    {
        var stack = new StackPanel
        {
            Spacing = 10,
            MaxWidth = 440,
            Padding = new Thickness(24),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var icon = Kit.Glyph(glyph, 34, Kit.Secondary);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(icon);

        var heading = Kit.Text(title, 18, bold: true);
        heading.HorizontalTextAlignment = TextAlignment.Center;
        stack.Children.Add(heading);

        var body = Kit.Text(words, 14, secondary: true);
        body.HorizontalTextAlignment = TextAlignment.Center;
        stack.Children.Add(body);

        var buttons = new StackPanel { Spacing = 8, Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var action in actions)
        {
            if (action is FrameworkElement fe) fe.HorizontalAlignment = HorizontalAlignment.Center;
            buttons.Children.Add(action);
        }
        stack.Children.Add(buttons);
        AutomationProperties.SetAutomationId(stack, automationId);
        return stack;
    }

    private void NoteTrouble(string? words)
    {
        if (_troubleWords == words) return;
        _troubleWords = words;
        if (string.IsNullOrEmpty(words))
        {
            _troubleBar.Child = null;
            _troubleBar.Visibility = Visibility.Collapsed;
            return;
        }
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Kit.Glyph(Kit.Warning, 16, Kit.Caution));
        var msg = Kit.Text(words, 13);
        msg.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(msg, 1);
        grid.Children.Add(msg);
        var retry = Kit.Button("Try Again", Reload);
        AutomationProperties.SetAutomationId(retry, "plugin-web-page.trouble-retry");
        Grid.SetColumn(retry, 2);
        grid.Children.Add(retry);
        _troubleBar.Child = grid;
        _troubleBar.Visibility = _phase == Phase.Ready ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetAutomationId(_troubleBar, "plugin-web-page.trouble");
    }

    private static bool CanAskRestart()
    {
        var client = AppState.Client;
        if (client == null) return false;
        return client.Bots?.Any(b => b.IsDefault || b.Name == "default") == true;
    }

    private async Task AskMainBotToRestartAsync()
    {
        if (_askingRestart || _target == null || AppState.Client is not { } client) return;
        var mainBot = client.Bots?.FirstOrDefault(b => b.IsDefault) ?? client.Bots?.FirstOrDefault(b => b.Name == "default");
        if (mainBot == null)
        {
            _askNote = "Couldn’t find your main bot to send a restart request.";
            RenderStatusOverlay();
            return;
        }
        _askingRestart = true;
        _askNote = null;
        RenderStatusOverlay();
        try
        {
            var chatId = await client.BotChatIdAsync(mainBot);
            var prompt = PluginPageRestart.Prompt(_target.Page.Label, _target.Page.Name, _target.BotName);
            Navigator.Go(new ChatDestination(mainBot.Name, chatId, mainBot.DisplayName, Draft: prompt));
        }
        catch (Exception ex)
        {
            _askNote = CapabilitiesWords.Detail(ex);
        }
        finally
        {
            _askingRestart = false;
            if (!_disposed) RenderStatusOverlay();
        }
    }

    private static string PageUrlPath(PluginDashboardPage page) =>
        page.TabPath.StartsWith('/') ? page.TabPath : "/" + page.TabPath;

    private static byte[]? ReadHostAsset(string fileName)
    {
        try
        {
            var path = Path.Combine(AssetsDir, fileName);
            return File.Exists(path) ? File.ReadAllBytes(path) : null;
        }
        catch (Exception) { return null; }
    }

    private static string ReadHostAssetText(string fileName) =>
        ReadHostAsset(fileName) is { } bytes ? Encoding.UTF8.GetString(bytes) : "";

    private void DisposeWeb()
    {
        if (_web == null) return;
        var web = _web;
        _web = null;
        _webHost.Children.Remove(web);
        try { web.Close(); } catch (Exception) { }
    }

    private void Cleanup()
    {
        _disposed = true;
        ThemeService.Changed -= OnThemeChanged;
        _loadCts?.Cancel();
        _loadCts = null;
        _watchdogCts?.Cancel();
        _watchdogCts = null;
        UiTree.DeactivateProgressRings(_statusOverlay);
        DisposeWeb();
    }
}
