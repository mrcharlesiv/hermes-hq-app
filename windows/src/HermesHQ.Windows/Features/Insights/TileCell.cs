using Hermes.Core;
using Hermes.Core.Insights;
using Hermes.Core.Net;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace HermesHQ.Features.Insights;

/// What a tile shows, read once and kept while the app runs (App/Pages/Artifacts/PinnedArtifacts.swift `PinPictures`):
/// a page's text and head, an image's bytes, or why it couldn't be read.
public sealed class TilePictures
{
    public sealed class Entry
    {
        public string? Html;
        public TileNames.Head? Head;
        public byte[]? Image;
        public string? Failure;
        public bool Gone;
        public DateTimeOffset ReadAt;
        public Task? Reading;
    }

    private static readonly Dictionary<string, TilePictures> Accounts = [];
    public static TilePictures Of(string account) => Accounts.TryGetValue(account, out var p) ? p : Accounts[account] = new();

    private readonly Dictionary<string, Entry> _entries = [];

    public Entry? Get(string id) => _entries.GetValueOrDefault(id);

    /// Reads `pin` (again when `fresh`). `done` runs on the caller's thread once it's read.
    public Task ReadAsync(GatewaySession session, TilePin pin, bool fresh)
    {
        if (!_entries.TryGetValue(pin.Id, out var e)) _entries[pin.Id] = e = new Entry();
        if (e.Reading is { IsCompleted: false } running) return running;
        if (!fresh && (e.Html != null || e.Image != null || e.Gone)) return Task.CompletedTask;
        return e.Reading = Read(session, pin, e);
    }

    private static async Task Read(GatewaySession session, TilePin pin, Entry e)
    {
        try
        {
            switch (TileFiles.OpeningOf(pin))
            {
                case TileFiles.Opening.Html:
                    var html = await TileFiles.TextAsync(session, pin);
                    e.Html = html;
                    e.Head = TileNames.ReadHead(html);
                    break;
                case TileFiles.Opening.Image when !TileFiles.IsHosted(pin):
                    e.Image = await TileFiles.ImageAsync(session, pin);
                    break;
                default:
                    return;
            }
            e.Failure = null;
            e.Gone = false;
        }
        catch (Exception x) when (x is GatewayException or PagesMessageException or OperationCanceledException)
        {
            e.Failure = TileFiles.FailureText(x, pin.Kind == TileKind.Image);
            e.Gone = TileFiles.IsMissing(x);
        }
        e.ReadAt = DateTimeOffset.UtcNow;
    }
}

/// One tile on the Tiles page, drawn as Grid's picture tile, a card, or a list row (PinTileView, PinCardView, the
/// list's row). Its picture: a page drawn by a WebView2 (live, with its buttons, when the page asks for it), an image,
/// else the kind's glyph. The health mark sits on the picture's top-right corner.
public sealed class TileCell : Grid
{
    public TilePin Pin { get; private set; }
    private readonly Border _picture;
    private readonly Grid _pictureContent;
    private readonly Border _workingVeil;
    private readonly ProgressRing _workingRing;
    private readonly TextBlock _workingText;
    private readonly Border _changedRing;
    private readonly TextBlock _name;
    private readonly TextBlock? _subtitle;
    private readonly Border _mark;
    private readonly Button _unpinBadge;
    private readonly Button _resizeHandle;
    private readonly TilesView _view;
    private WebView2? _web;
    private string? _shownHtml;
    private string? _themeKey;
    private bool _live;
    private bool _editing;
    private bool _selected;
    private int _gridColumns = 2;
    private double _gridSide = 180, _gridSpacing = 12;
    private uint? _resizePointer;
    private Point _resizeStartPoint;
    private double _resizeStartWidth, _resizeStartHeight;
    private bool _resizeDragged;

    /// Last time this cell was displayed on screen (used by the TilesPage warm WebView2 pool).
    public DateTimeOffset ShownAt { get; set; } = DateTimeOffset.UtcNow;

    /// A click on the tile (open it), a page's message (a button's ask, open, refresh), unpin, resize, or batch selection.
    public event Action<TileCell>? Activated;
    public event Action<TileCell, TileWeb.Message, WebView2>? WebMessage;
    public event Action<TileCell>? UnpinRequested;
    public event Action<TileCell, TileSize>? ResizeRequested;
    public event Action<TileCell>? SelectionToggled;

    public const double Radius = 16;

    public static string Glyph(TilePin pin, bool failed)
    {
        if (failed) return pin.IsPage ? "" : "";
        if (pin.IsPage) return "";                 // a chart (the Mac's chart.xyaxis.line)
        if (pin.Kind == TileKind.Image) return "";  // photo
        if (pin.Kind == TileKind.Link) return "";   // link
        return "";                                  // document
    }

    public TileCell(TilePin pin, TilesView view, bool showsName, string subtitle)
    {
        Pin = pin;
        _view = view;
        _pictureContent = new Grid();
        _picture = new Border
        {
            CornerRadius = new CornerRadius(view == TilesView.List ? 8 : Radius),
            Background = Kit.Brush("CardBackgroundFillColorSecondaryBrush"),
            BorderBrush = Kit.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
            Child = _pictureContent,
        };
        _mark = new Border { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(7), Visibility = Visibility.Collapsed };
        _unpinBadge = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 11 }, Width = 26, Height = 26, Padding = new Thickness(0),
            CornerRadius = new CornerRadius(13), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(-8, -8, 0, 0), Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_unpinBadge, "pin.unpin-badge");
        _unpinBadge.Click += (_, _) => UnpinRequested?.Invoke(this);

        // [tiles-v2] Blue corner resize handle in Edit mode: drag to snap Small/Medium/Tall/Banner/Large/Extra Large,
        // or click to cycle cleanly through sizes.
        _resizeHandle = new Button
        {
            Content = new FontIcon { Glyph = "\uE740", FontSize = 10, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) },
            Width = 24, Height = 24, Padding = new Thickness(0), CornerRadius = new CornerRadius(12),
            Background = Kit.Brush("AccentFillColorDefaultBrush"), BorderThickness = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, -6, -6), Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_resizeHandle, "pin.resize-handle");
        _resizeHandle.PointerPressed += OnResizePressed;
        _resizeHandle.PointerMoved += OnResizeMoved;
        _resizeHandle.PointerReleased += OnResizeReleased;
        _resizeHandle.PointerCaptureLost += OnResizeReleased;
        _resizeHandle.Click += (_, _) =>
        {
            if (_resizeDragged) { _resizeDragged = false; return; }
            var idx = Array.IndexOf(TileSizes.All, Pin.TileSize);
            var next = TileSizes.All[(idx + 1) % TileSizes.All.Length];
            ResizeRequested?.Invoke(this, next);
        };

        _workingRing = new ProgressRing { Width = 14, Height = 14, IsActive = false, VerticalAlignment = VerticalAlignment.Center };
        _workingText = new TextBlock
        {
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = Kit.Brush("TextFillColorPrimaryBrush"),
        };
        var workingPill = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(10, 5, 12, 5),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(8, 0, 8, 10),
            Background = Kit.Brush("AcrylicInAppFillColorDefaultBrush"),
            BorderBrush = Kit.Brush("AccentFillColorDefaultBrush"),
            BorderThickness = new Thickness(1.5),
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children = { _workingRing, _workingText },
            },
        };
        _workingVeil = new Border
        {
            CornerRadius = _picture.CornerRadius,
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x4D, 0, 0, 0)),
            BorderBrush = Kit.Brush("AccentFillColorDefaultBrush"),
            BorderThickness = new Thickness(1.5),
            Child = workingPill,
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_workingVeil, "tile.changing.veil");

        _changedRing = new Border
        {
            CornerRadius = _picture.CornerRadius,
            BorderBrush = Kit.Brush("AccentFillColorDefaultBrush"),
            BorderThickness = new Thickness(3),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_changedRing, "tile.changed.ring");

        _name = new TextBlock { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, Foreground = Kit.Brush("TextFillColorSecondaryBrush") };
        var pictureHost = new Grid { Children = { _picture, _workingVeil, _changedRing, _mark, _unpinBadge, _resizeHandle } };

        switch (view)
        {
            case TilesView.Grid:
                RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
                RowDefinitions.Add(new RowDefinition { Height = showsName ? new GridLength(22) : new GridLength(0) });
                Children.Add(pictureHost);
                _name.HorizontalAlignment = HorizontalAlignment.Center;
                _name.Margin = new Thickness(4, 4, 4, 0);
                SetRow(_name, 1);
                if (showsName) Children.Add(_name);
                break;
            case TilesView.Cards:
            {
                var card = new Grid();
                card.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
                card.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                _picture.CornerRadius = new CornerRadius(Radius, Radius, 0, 0);
                _workingVeil.CornerRadius = _picture.CornerRadius;
                _changedRing.CornerRadius = _picture.CornerRadius;
                _picture.BorderThickness = new Thickness(0, 0, 0, 1);
                card.Children.Add(pictureHost);
                _name.FontSize = 14; _name.FontWeight = FontWeights.SemiBold; _name.Foreground = Kit.Brush("TextFillColorPrimaryBrush");
                _subtitle = new TextBlock { Text = subtitle, FontSize = 12, Foreground = Kit.Brush("TextFillColorSecondaryBrush"), TextTrimming = TextTrimming.CharacterEllipsis };
                var foot = new StackPanel { Padding = new Thickness(12, 8, 12, 9), Spacing = 1, Children = { _name, _subtitle } };
                SetRow(foot, 1);
                card.Children.Add(foot);
                Children.Add(new Border
                {
                    Child = card, CornerRadius = new CornerRadius(Radius), Background = Kit.Brush("CardBackgroundFillColorDefaultBrush"),
                    BorderBrush = Kit.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
                });
                break;
            }
            default:
            {
                ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
                ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                Padding = new Thickness(16, 6, 16, 6);
                ColumnSpacing = 12;
                pictureHost.Height = 44;
                Children.Add(pictureHost);
                _name.FontSize = 14; _name.Foreground = Kit.Brush("TextFillColorPrimaryBrush");
                _subtitle = new TextBlock { Text = subtitle, FontSize = 12, Foreground = Kit.Brush("TextFillColorSecondaryBrush"), TextTrimming = TextTrimming.CharacterEllipsis };
                var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 1, Children = { _name, _subtitle } };
                SetColumn(words, 1);
                Children.Add(words);
                _mark.Margin = new Thickness(-6);
                break;
            }
        }
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        Tapped += (_, e) =>
        {
            e.Handled = true;
            if (_editing) SelectionToggled?.Invoke(this);
            else Activated?.Invoke(this);
        };
        IsTabStop = false;
        AutomationProperties.SetAutomationId(this, "pin.tile");
        SetName(pin.Name);
    }

    /// Provides the current Grid metrics so corner resize dragging snaps accurately to grid columns and rows.
    public void SetGridMetrics(int columns, double cellSide, double spacing)
    {
        _gridColumns = Math.Max(2, columns);
        _gridSide = Math.Max(60, cellSide);
        _gridSpacing = Math.Max(4, spacing);
    }

    private void OnResizePressed(object sender, PointerRoutedEventArgs e)
    {
        if (!_editing || _view != TilesView.Grid) return;
        _resizePointer = e.Pointer.PointerId;
        _resizeStartPoint = e.GetCurrentPoint(Parent as UIElement ?? this).Position;
        _resizeStartWidth = ActualWidth > 0 ? ActualWidth : _gridSide;
        _resizeStartHeight = ActualHeight > 0 ? ActualHeight : _gridSide;
        _resizeDragged = false;
        _resizeHandle.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnResizeMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_resizePointer != e.Pointer.PointerId) return;
        var pos = e.GetCurrentPoint(Parent as UIElement ?? this).Position;
        var dx = pos.X - _resizeStartPoint.X;
        var dy = pos.Y - _resizeStartPoint.Y;
        if (Math.Abs(dx) > 6 || Math.Abs(dy) > 6) _resizeDragged = true;
        if (!_resizeDragged) return;
        var step = _gridSide + _gridSpacing;
        var across = Math.Max(1, (int)Math.Round((_resizeStartWidth + dx + _gridSpacing) / step));
        var down = Math.Max(1, (int)Math.Round((_resizeStartHeight + dy + _gridSpacing) / step));
        var fitted = TileSizes.Fitting(across, down, _gridColumns);
        if (fitted != Pin.TileSize) ResizeRequested?.Invoke(this, fitted);
        e.Handled = true;
    }

    private void OnResizeReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_resizePointer != e.Pointer.PointerId) return;
        _resizePointer = null;
        _resizeHandle.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    /// The pin as it is now (a new size, name or page): the same picture stays.
    public void Update(TilePin pin)
    {
        Pin = pin;
        AutomationProperties.SetName(_resizeHandle, $"Resize {_name.Text} ({pin.TileSize.Title()})");
    }

    public void SetName(string name)
    {
        _name.Text = name;
        AutomationProperties.SetName(this, name);
        AutomationProperties.SetName(_resizeHandle, $"Resize {name} ({Pin.TileSize.Title()})");
    }

    public void SetSubtitle(string text) { if (_subtitle != null) _subtitle.Text = text; }

    public void SetSelected(bool selected)
    {
        _selected = selected && _editing;
        _picture.BorderBrush = _selected ? Kit.Brush("AccentFillColorDefaultBrush") : Kit.Brush("CardStrokeColorDefaultBrush");
        _picture.BorderThickness = new Thickness(_selected ? 2 : 1);
    }

    /// Edit Tiles: the unpin badge and blue corner resize handle on Grid tiles, no live page hits during drag/edit.
    public void SetEditing(bool editing)
    {
        _editing = editing;
        var gridEdit = editing && _view == TilesView.Grid;
        _unpinBadge.Visibility = gridEdit ? Visibility.Visible : Visibility.Collapsed;
        _resizeHandle.Visibility = gridEdit ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(_unpinBadge, $"Unpin {_name.Text}");
        AutomationProperties.SetName(_resizeHandle, $"Resize {_name.Text} ({Pin.TileSize.Title()})");
        if (!editing && _selected) SetSelected(false);
        if (_web != null) _web.IsHitTestVisible = _live && !editing;
    }

    /// The health mark (TileHealthMark): red ! when the last update failed, a clock when late, pause when paused, a
    /// ring while its job runs; nothing when all is well.
    public void SetHealth(TileJobs.Health health)
    {
        UIElement? content = health.Kind switch
        {
            TileJobs.HealthKind.Failed => new FontIcon { Glyph = "", FontSize = 11, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) },
            TileJobs.HealthKind.Late => new FontIcon { Glyph = "", FontSize = 11 },
            TileJobs.HealthKind.Paused => new FontIcon { Glyph = "", FontSize = 9 },
            TileJobs.HealthKind.Updating => new ProgressRing { Width = 12, Height = 12, IsActive = true },
            _ => null,
        };
        HermesHQ.Services.UiTree.DeactivateProgressRings(_mark);
        if (content == null) { _mark.Visibility = Visibility.Collapsed; _mark.Child = null; }
        else
        {
            var failed = health.Kind == TileJobs.HealthKind.Failed;
            _mark.Child = new Grid { Width = 22, Height = 22, Children = { content } };
            _mark.Width = _mark.Height = 22;
            _mark.CornerRadius = new CornerRadius(11);
            _mark.Background = failed ? new SolidColorBrush(Kit.Red) : Kit.Brush("AcrylicInAppFillColorDefaultBrush");
            _mark.BorderBrush = Kit.Brush("CardStrokeColorDefaultBrush");
            _mark.BorderThickness = new Thickness(failed ? 0 : 1);
            _mark.Visibility = Visibility.Visible;
            AutomationProperties.SetAutomationId(_mark, "tile.health." + health.Kind.ToString().ToLowerInvariant());
        }
        var spoken = TileJobs.Spoken(health);
        AutomationProperties.SetName(this, spoken == null ? _name.Text : $"{_name.Text}, {spoken}");
    }

    /// [tiles-v2] Shows or hides the inline `TileChangingVeil` overlay while a bot is changing/updating this tile.
    public void SetWorking(string? words)
    {
        var show = !string.IsNullOrWhiteSpace(words);
        _workingText.Text = words ?? "";
        _workingRing.IsActive = show;
        _workingVeil.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    /// [tiles-v2] Shows or hides the brief `TileChangedRing` accent outline after a change finishes.
    public void SetRinged(bool ringed) => _changedRing.Visibility = ringed ? Visibility.Visible : Visibility.Collapsed;

    /// [28b14acf7] Updates the tile's live WebView2 theme in place via `window.__hqApplyTheme`, reloading only if needed.
    public async Task ApplyThemeAsync(bool dark)
    {
        var key = TileWeb.ThemeKey(dark);
        if (_web?.CoreWebView2 == null) { _themeKey = key; return; }
        if (_themeKey == key) return;
        _themeKey = key;
        var needsReload = await TileWeb.ApplyThemeAsync(_web, dark);
        if (needsReload && _shownHtml != null && _web?.CoreWebView2 != null)
            TileWeb.Show(_web, _shownHtml);
    }

    /// Captures a PNG snapshot of this tile's live WebView2 (null when no live WebView is active).
    public Task<byte[]?> CapturePngAsync() =>
        _web != null ? TileWeb.CapturePngAsync(_web) : Task.FromResult<byte[]?>(null);

    /// Draws what was read: the page (in its web view), the image, or the glyph (a gone file's broken mark).
    public void ShowPicture(TilePictures.Entry? entry, bool showsName, bool dark, bool allowWeb)
    {
        ShownAt = DateTimeOffset.UtcNow;
        var failed = entry is { Gone: true } || (entry?.Failure != null && entry.Html == null && entry.Image == null);
        if (Pin.IsPage && entry?.Html is { } html && allowWeb)
        {
            _live = entry.Head?.Live == true;
            if (_web == null)
            {
                HermesHQ.Services.UiTree.ClearPanel(_pictureContent);
                _web = new WebView2 { IsHitTestVisible = _live && !_editing, IsTabStop = _live };
                AutomationProperties.SetAutomationId(_web, "live-tile");
                _pictureContent.Children.Add(_web);
                _ = StartWeb(_web, html, dark);
            }
            else if (_web.CoreWebView2 != null)
            {
                if (_shownHtml != html)
                {
                    _shownHtml = html;
                    TileWeb.Show(_web, html);
                }
                if (_themeKey != TileWeb.ThemeKey(dark))
                    _ = ApplyThemeAsync(dark);
            }
            _web.IsHitTestVisible = _live && !_editing;
            return;
        }
        if (Pin.Kind == TileKind.Image && !failed)
        {
            BitmapImage? bitmap = null;
            if (TileFiles.IsHosted(Pin) && Uri.TryCreate(Pin.Value, UriKind.Absolute, out var u) && u.Scheme == "https")
                bitmap = new BitmapImage(u);
            else if (entry?.Image is { } bytes)
            {
                bitmap = new BitmapImage { DecodePixelWidth = 480 };
                _ = SetSource(bitmap, bytes);
            }
            if (bitmap != null)
            {
                CloseWeb();
                HermesHQ.Services.UiTree.ClearPanel(_pictureContent);
                _pictureContent.Children.Add(new Image { Source = bitmap, Stretch = Stretch.UniformToFill, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
                return;
            }
        }
        CloseWeb();
        HermesHQ.Services.UiTree.ClearPanel(_pictureContent);
        var busy = entry == null && (Pin.IsPage || Pin.Kind == TileKind.Image);
        if (busy)
        {
            _pictureContent.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20 });
            return;
        }
        var stack = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        stack.Children.Add(new FontIcon
        {
            Glyph = Glyph(Pin, failed), FontSize = _view == TilesView.List ? 18 : 26,
            Foreground = failed ? Kit.Brush("TextFillColorTertiaryBrush") : Kit.Brush("AccentTextFillColorPrimaryBrush"),
        });
        if (_view == TilesView.Grid && !showsName && (failed || (!Pin.IsPage && Pin.Kind != TileKind.Image)))
            stack.Children.Add(new TextBlock
            {
                Text = _name.Text, FontSize = 12, FontWeight = FontWeights.Medium, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap,
                MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(10, 0, 10, 0),
            });
        _pictureContent.Children.Add(stack);
    }

    private static async Task SetSource(BitmapImage bitmap, byte[] bytes)
    {
        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        await stream.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(bytes));
        stream.Seek(0);
        try { await bitmap.SetSourceAsync(stream); }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or ArgumentException) { }
    }

    private async Task StartWeb(WebView2 web, string html, bool dark)
    {
        _themeKey = TileWeb.ThemeKey(dark);
        if (!await TileWeb.PrepareAsync(web, dark, talks: true, inTile: true)) return;
        if (web != _web) return;
        web.CoreWebView2.WebMessageReceived += (_, e) =>
        {
            if (TileWeb.Read(e) is { } m) WebMessage?.Invoke(this, m, web);
        };
        _shownHtml = html;
        TileWeb.Show(web, html);
    }

    /// The tile's page is read again (a live tile's refresh, its job ran).
    public void Reload(string html)
    {
        if (_web?.CoreWebView2 == null || html == _shownHtml) return;
        _shownHtml = html;
        TileWeb.Show(_web, html);
    }

    public void CloseWeb()
    {
        _workingRing.IsActive = false;
        HermesHQ.Services.UiTree.DeactivateProgressRings(this);
        if (_web is { } web)
        {
            _web = null;
            _shownHtml = null;
            _themeKey = null;
            _pictureContent.Children.Remove(web);
            try { web.Close(); } catch (Exception) { }
        }
    }

    public bool HasWeb => _web != null;
}
