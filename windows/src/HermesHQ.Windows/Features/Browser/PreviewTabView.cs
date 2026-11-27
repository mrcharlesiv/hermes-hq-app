// [preview-tab] WebView2 preview tab window for the bot's `desktop_preview` tool (C# twin of
// App/Browser/PreviewTab.swift): Back / Forward / Reload / Site address / Copy Link / Open Outside / Close toolbar
// plus `ReadPageAsync` returning PreviewTabRules.Answer JSON.

using System.Text.Json;
using Hermes.Core.Browser;
using HermesHQ.Features.Capabilities;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.System;
using Kit = HermesHQ.Features.Capabilities.Kit;

namespace HermesHQ.Features.Browser;

public sealed class PreviewTabWindow : Window
{
    private static PreviewTabWindow? _showing;
    public static PreviewTabWindow? Showing => _showing;
    public static void CloseOpen() => _showing?.Close();

    private readonly WebView2 _webView = new();
    private readonly Button _backButton;
    private readonly Button _forwardButton;
    private readonly Button _reloadButton;
    private readonly TextBlock _siteText;
    private readonly Button _copyButton;
    private readonly Button _openOutsideButton;
    private readonly Button _closeButton;
    private Uri _currentUrl;
    private bool _closed;

    public Uri CurrentUrl => _currentUrl;

    private PreviewTabWindow(Uri initialUrl)
    {
        _currentUrl = initialUrl;
        _showing = this;
        Title = PreviewTabRules.Site(initialUrl);

        var root = new Grid
        {
            Background = ThemeService.BrushFor("HQPageBrush"),
        };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var bar = new Grid { Padding = new Thickness(10, 8, 10, 8), ColumnSpacing = 4 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // back
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // forward
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // reload
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); // site
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // copy
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // open outside
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // close

        _backButton = NavButton("\uE72B", "Back", "preview.back", () => { if (_webView.CanGoBack) _webView.GoBack(); });
        _forwardButton = NavButton("\uE72A", "Forward", "preview.forward", () => { if (_webView.CanGoForward) _webView.GoForward(); });
        _reloadButton = NavButton("\uE72C", "Reload", "preview.reload", () => { if (_webView.CoreWebView2 != null) _webView.Reload(); else _ = EnsureAndNavigateAsync(_currentUrl); });

        _siteText = new TextBlock
        {
            Text = PreviewTabRules.Site(initialUrl),
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var sitePill = new Border
        {
            Child = _siteText,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(12, 6, 12, 6),
            Background = Kit.Brush("ControlFillColorDefaultBrush"),
            Margin = new Thickness(6, 0, 6, 0),
        };

        _copyButton = NavButton("\uE8C8", "Copy Link", "preview.copy", () => Kit.Copy(_currentUrl.AbsoluteUri));
        _openOutsideButton = NavButton("\uE8A7", "Open in Browser", "preview.openOutside", () => _ = Launcher.LaunchUriAsync(_currentUrl));
        _closeButton = NavButton("\uE711", "Close", "preview.close", Close);

        Grid.SetColumn(_backButton, 0); bar.Children.Add(_backButton);
        Grid.SetColumn(_forwardButton, 1); bar.Children.Add(_forwardButton);
        Grid.SetColumn(_reloadButton, 2); bar.Children.Add(_reloadButton);
        Grid.SetColumn(sitePill, 3); bar.Children.Add(sitePill);
        Grid.SetColumn(_copyButton, 4); bar.Children.Add(_copyButton);
        Grid.SetColumn(_openOutsideButton, 5); bar.Children.Add(_openOutsideButton);
        Grid.SetColumn(_closeButton, 6); bar.Children.Add(_closeButton);

        root.Children.Add(bar);
        Grid.SetRow(_webView, 1);
        root.Children.Add(_webView);
        Content = root;

        try
        {
            var scale = App.Window?.Content?.XamlRoot?.RasterizationScale ?? 1.0;
            AppWindow.Resize(new SizeInt32((int)(1020 * scale), (int)(740 * scale)));
            if (AppWindow.Presenter is OverlappedPresenter p)
            {
                p.PreferredMinimumWidth = (int)(480 * scale);
                p.PreferredMinimumHeight = (int)(360 * scale);
            }
        }
        catch (Exception e) { AppLog.Note("browser", $"preview window sizing failed ({e.GetType().Name})"); }

        _webView.NavigationCompleted += (_, _) => UpdateNavigationState();
        _ = EnsureAndNavigateAsync(initialUrl);

        FollowTheme();
        ThemeService.Changed += FollowTheme;
        Closed += (_, _) =>
        {
            _closed = true;
            ThemeService.Changed -= FollowTheme;
            try { _webView.Close(); } catch (Exception) { }
            if (_showing == this) _showing = null;
        };
    }

    public static PreviewTabWindow Open(Uri url)
    {
        if (_showing is { } open)
        {
            open.Navigate(url);
            open.Activate();
            return open;
        }
        var window = new PreviewTabWindow(url);
        window.Activate();
        return window;
    }

    public void Navigate(Uri url)
    {
        if (_closed) return;
        _currentUrl = url;
        _siteText.Text = PreviewTabRules.Site(url);
        Title = _siteText.Text;
        _ = EnsureAndNavigateAsync(url);
        UpdateNavigationState();
    }

    private async Task EnsureAndNavigateAsync(Uri url)
    {
        if (_closed || AppShutdown.Stopping) return;
        try
        {
            if (_webView.CoreWebView2 == null)
            {
                var env = await WebViewEnv.GetAsync();
                if (_closed || AppShutdown.Stopping) return;
                await _webView.EnsureCoreWebView2Async(env);
            }
            if (_closed || AppShutdown.Stopping) return;
            _webView.Source = url;
        }
        catch (Exception e) { AppLog.Note("browser", $"preview navigate failed: {e.GetType().Name}"); }
    }

    public async Task<string?> ReadPageAsync(int? start = null, int? count = null)
    {
        if (_closed || AppShutdown.Stopping) return null;
        try
        {
            if (_webView.CoreWebView2 == null)
            {
                var env = await WebViewEnv.GetAsync();
                if (_closed || AppShutdown.Stopping) return null;
                await _webView.EnsureCoreWebView2Async(env);
            }
            if (_closed || _webView.CoreWebView2 == null) return null;
            var raw = await _webView.ExecuteScriptAsync(
                "JSON.stringify({ url: location.href, title: document.title || '', text: (document.body && document.body.innerText) || '' })");
            if (string.IsNullOrEmpty(raw) || raw == "null") return null;
            var json = JsonSerializer.Deserialize<string>(raw);
            if (string.IsNullOrEmpty(json)) return null;
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var url = root.TryGetProperty("url", out var u) ? u.GetString() ?? _currentUrl.AbsoluteUri : _currentUrl.AbsoluteUri;
            var title = root.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "";
            var text = root.TryGetProperty("text", out var txt) ? txt.GetString() ?? "" : "";
            return PreviewTabRules.Answer(new PreviewPage(url, title, text), start, count);
        }
        catch (Exception) { return null; }
    }

    private void UpdateNavigationState()
    {
        if (_webView.Source is { } src)
        {
            _currentUrl = src;
            _siteText.Text = PreviewTabRules.Site(src);
            Title = _siteText.Text;
        }
        _backButton.IsEnabled = _webView.CanGoBack;
        _forwardButton.IsEnabled = _webView.CanGoForward;
    }

    private void FollowTheme()
    {
        if (App.Window?.Content is FrameworkElement main && Content is FrameworkElement root)
            root.RequestedTheme = main.RequestedTheme;
    }

    private static Button NavButton(string glyph, string name, string automationId, Action click)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            MinWidth = 36,
            MinHeight = 36,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        AutomationProperties.SetName(button, name);
        AutomationProperties.SetAutomationId(button, automationId);
        ToolTipService.SetToolTip(button, name);
        button.Click += (_, _) => click();
        return button;
    }
}
