using Hermes.Core.Insights;
using Hermes.Core.Net;
using HermesHQ.Controls;
using HermesHQ.Features.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace HermesHQ.Features.Insights;

/// An opened tile (HTMLPageSheet over the Tiles page, the Mac's sheet in 37-tile-open-desktop-light.png): its name and
/// "file.html · updated 5 min ago" over the page, Reload, Share… and Done in its bar. A page is live (its buttons ask
/// the bot); an image fits the sheet; Markdown and text read as they do in a chat. Escape or Done closes it.
/// Supports in-place WebView2 theme switching via `window.__hqApplyTheme(css, isDark, ground)`.
public sealed class TileViewer : Grid
{
    private readonly GatewaySession _session;
    private readonly TilePin _pin;
    private readonly Border _body;
    private readonly TextBlock _sub;
    private readonly string _fileName;
    private readonly DispatcherQueue _ui;
    private WebView2? _web;
    private string? _shownHtml;
    private string? _themeKey;
    private bool _closed;

    public event Action? Closed;
    /// A page's button asked its bot: the page answers with the ack.
    public event Action<TilePin, TileWeb.Message, WebView2>? WebMessage;
    public event Action<TilePin>? ShareRequested;

    public TileViewer(GatewaySession session, TilePin pin, string name, string? status)
    {
        _session = session;
        _pin = pin;
        _fileName = pin.Label;
        _ui = DispatcherQueue.GetForCurrentThread();
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x66, 0, 0, 0));
        var title = new TextBlock { Text = name, FontWeight = FontWeights.SemiBold, FontSize = 15, HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        _sub = new TextBlock { FontSize = 12, Foreground = Kit.Brush("TextFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        SetStatus(status);
        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { title, _sub } };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        if (pin.IsPage) buttons.Children.Add(Kit.BarButton("", "Reload", () => _ = LoadAsync(fresh: true)));
        buttons.Children.Add(Kit.BarButton("", "Share…", () => ShareRequested?.Invoke(_pin)));
        var done = new Button { Content = TileWords.Done, FontWeight = FontWeights.SemiBold, Margin = new Thickness(8, 0, 0, 0) };
        done.Click += (_, _) => Close();
        buttons.Children.Add(done);
        var bar = new Grid { Padding = new Thickness(16, 10, 12, 10), MinHeight = 56, Children = { words, buttons } };
        _body = new Border();
        var sheet = new Grid
        {
            MaxWidth = 780, Margin = new Thickness(24, 40, 24, 24), CornerRadius = new CornerRadius(14),
            Background = Kit.Brush("SolidBackgroundFillColorBaseBrush"),
            BorderBrush = Kit.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
        };
        sheet.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        sheet.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        sheet.Children.Add(bar);
        SetRow(_body, 1);
        sheet.Children.Add(_body);
        Children.Add(sheet);
        AutomationProperties.SetAutomationId(sheet, "tile.sheet");
        // A click on the dimmed edge closes it, as a sheet's does.
        Tapped += (_, e) => { if (ReferenceEquals(e.OriginalSource, this)) Close(); };
        KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; Close(); } };
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        KeyboardAccelerators.Add(Accel(Windows.System.VirtualKey.R, () => _ = LoadAsync(fresh: true)));
        ActualThemeChanged += (_, _) => _ = ApplyThemeAsync();
        ThemeService.Changed += OnThemeServiceChanged;
        Loaded += (_, _) => { done.Focus(FocusState.Programmatic); _ = LoadAsync(fresh: false); };
    }

    private void OnThemeServiceChanged() => _ui.TryEnqueue(() => { if (!_closed) _ = ApplyThemeAsync(); });

    private async Task ApplyThemeAsync()
    {
        if (_closed || _web?.CoreWebView2 == null) return;
        var dark = ActualTheme == ElementTheme.Dark;
        var key = TileWeb.ThemeKey(dark);
        if (_themeKey == key) return;
        _themeKey = key;
        var needsReload = await TileWeb.ApplyThemeAsync(_web, dark);
        if (needsReload && !_closed && _shownHtml != null && _web?.CoreWebView2 != null)
            TileWeb.Show(_web, _shownHtml);
    }

    public WebView2? WebView => _web;

    private static KeyboardAccelerator Accel(Windows.System.VirtualKey key, Action run)
    {
        var a = new KeyboardAccelerator { Key = key, Modifiers = Windows.System.VirtualKeyModifiers.Control };
        a.Invoked += (_, e) => { e.Handled = true; run(); };
        return a;
    }

    /// "file.html · updated 5 min ago" (the job's short status), or the file name alone.
    public void SetStatus(string? status) => _sub.Text = status == null ? _fileName : $"{_fileName} · {status}";

    public void Close()
    {
        if (_closed) return;
        _closed = true;
        ThemeService.Changed -= OnThemeServiceChanged;
        HermesHQ.Services.UiTree.DeactivateProgressRings(_body);
        CloseWeb();
        Closed?.Invoke();
    }

    private void CloseWeb()
    {
        if (_web is { } web)
        {
            _web = null;
            _shownHtml = null;
            _themeKey = null;
            if (ReferenceEquals(_body.Child, web)) _body.Child = null;
            try { web.Close(); } catch (Exception) { }
        }
    }

    public TilePin Pin => _pin;

    /// The page read again (its job ran while it was open).
    public Task ReloadAsync() => LoadAsync(fresh: true);

    private async Task LoadAsync(bool fresh)
    {
        if (_closed) return;
        if (_body.Child == null) _body.Child = new ProgressRing { IsActive = true, Width = 28, Height = 28 };
        try
        {
            switch (TileFiles.OpeningOf(_pin))
            {
                case TileFiles.Opening.Html:
                {
                    var html = await TileFiles.TextAsync(_session, _pin);
                    if (_closed) return;
                    if (_web == null)
                    {
                        HermesHQ.Services.UiTree.DeactivateProgressRings(_body);
                        var web = new WebView2();
                        _web = web;
                        _body.Child = web;
                        var dark = ActualTheme == ElementTheme.Dark;
                        _themeKey = TileWeb.ThemeKey(dark);
                        if (!await TileWeb.PrepareAsync(web, dark, talks: true, inTile: false))
                        {
                            if (_closed || !ReferenceEquals(_web, web)) { try { web.Close(); } catch (Exception) { } }
                            return;
                        }
                        if (_closed || !ReferenceEquals(_web, web))
                        {
                            try { web.Close(); } catch (Exception) { }
                            return;
                        }
                        web.CoreWebView2.WebMessageReceived += (_, e) =>
                        {
                            if (!_closed && TileWeb.Read(e) is { } m && _web != null) WebMessage?.Invoke(_pin, m, _web);
                        };
                    }
                    _shownHtml = html;
                    TileWeb.Show(_web, html);
                    break;
                }
                case TileFiles.Opening.Image:
                {
                    BitmapImage bitmap;
                    if (TileFiles.IsHosted(_pin) && Uri.TryCreate(_pin.Value, UriKind.Absolute, out var u)) bitmap = new BitmapImage(u);
                    else
                    {
                        var bytes = await TileFiles.ImageAsync(_session, _pin);
                        if (_closed) return;
                        bitmap = new BitmapImage();
                        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
                        await stream.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(bytes));
                        stream.Seek(0);
                        await bitmap.SetSourceAsync(stream);
                    }
                    if (_closed) return;
                    HermesHQ.Services.UiTree.DeactivateProgressRings(_body);
                    _body.Child = new ScrollViewer
                    {
                        Content = new Image { Source = bitmap, Stretch = Stretch.Uniform }, ZoomMode = ZoomMode.Enabled,
                        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                    };
                    break;
                }
                case TileFiles.Opening.Markdown:
                {
                    var text = await TileFiles.TextAsync(_session, _pin);
                    if (_closed) return;
                    var panel = new StackPanel { Padding = new Thickness(20, 12, 20, 24), MaxWidth = 720 };
                    MarkdownRenderer.Render(text.Length > TileFiles.TextLimit ? text[..TileFiles.TextLimit] : text, panel);
                    HermesHQ.Services.UiTree.DeactivateProgressRings(_body);
                    _body.Child = new ScrollViewer { Content = panel };
                    break;
                }
                default:
                {
                    var text = await TileFiles.TextAsync(_session, _pin);
                    if (_closed) return;
                    HermesHQ.Services.UiTree.DeactivateProgressRings(_body);
                    _body.Child = new ScrollViewer
                    {
                        Content = new TextBlock
                        {
                            Text = text.Length > TileFiles.TextLimit ? text[..TileFiles.TextLimit] : text, IsTextSelectionEnabled = true,
                            FontFamily = (FontFamily)Application.Current.Resources["CodeFont"], FontSize = 12, Margin = new Thickness(20, 12, 20, 24),
                            TextWrapping = TextWrapping.Wrap,
                        },
                        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    };
                    break;
                }
            }
        }
        catch (Exception e) when (e is GatewayException or PagesMessageException or System.Runtime.InteropServices.COMException)
        {
            if (_closed) return;
            CloseWeb();
            HermesHQ.Services.UiTree.DeactivateProgressRings(_body);
            var image = _pin.Kind == TileKind.Image;
            _body.Child = Kit.Error("Couldn’t Open This File", TileFiles.FailureText(e, image),
                () => { _body.Child = null; _ = LoadAsync(fresh: true); });
        }
    }
}
