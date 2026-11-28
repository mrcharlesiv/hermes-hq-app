using Hermes.Core;
using Hermes.Core.Insights;
using Hermes.Core.QuickActions;
using HermesHQ.Features.Insights;
using HermesHQ.Features.Kanban;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;
using Windows.UI;

namespace HermesHQ.Features.QuickActions;

/// Dashboard tiles embedded on Favorites (`App/QuickActions/FavoriteDashboardTiles.swift`): bridges the signed-in
/// account's shared `TilePinStore`, `TileHidden`, and `TilePictures` cache so Dashboard pins appear as live preview
/// cards on Favorites and open in the full `TileViewer` overlay on click.
internal sealed class FavoriteTiles : IDisposable
{
    private HermesClient? _client;
    private TilePinStore? _pins;
    private TileHidden? _hidden;
    private TilePictures? _pictures;
    private bool _disposed;

    public bool Ready => _pins != null && _client != null;
    public IReadOnlyList<TilePage> Pages => _pins?.Pages ?? [TilePage.Main];
    public IReadOnlyList<TilePin> VisiblePins => _pins == null ? []
        : _hidden != null ? _hidden.Visible(_pins.Pins).ToList() : _pins.Pins.ToList();

    public event Action? Changed;

    public void Attach(HermesClient? client)
    {
        if (ReferenceEquals(_client, client)) return;
        Detach();
        _client = client;
        if (client == null) return;
        _pins = TilesPage.PinsFor(client);
        _hidden = new TileHidden(TilePinStore.FileFor(Path.Combine(AppPaths.Root, "pages", "hidden"), client.AccountId));
        _pictures = TilePictures.Of(client.AccountId);
        _pins.Changed += OnChanged;
        _hidden.Changed += OnChanged;
    }

    public void Detach()
    {
        if (_pins != null) _pins.Changed -= OnChanged;
        if (_hidden != null) _hidden.Changed -= OnChanged;
        _pins = null;
        _hidden = null;
        _pictures = null;
        _client = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Detach();
    }

    private void OnChanged() => Changed?.Invoke();

    public TilePin? Pin(string? id)
    {
        if (string.IsNullOrEmpty(id) || _pins == null) return null;
        var pin = _pins.Pins.FirstOrDefault(p => p.Id == id);
        if (pin == null) return null;
        return _hidden != null && _hidden.IsHidden(pin) ? null : pin;
    }

    public string Name(TilePin pin) => _pins?.Name(pin) ?? pin.Name;

    public TilePictures.Entry? Entry(string pinId) => _pictures?.Get(pinId);

    public async Task ReadAsync(TilePin pin, bool fresh)
    {
        if (_client == null || _pictures == null) return;
        await _pictures.ReadAsync(_client.Session, pin, fresh);
        var entry = _pictures.Get(pin.Id);
        if (entry?.Head is { } head && _pins != null) _pins.NotePage(pin.Id, head);
        Changed?.Invoke();
    }

    /// Ensures every Dashboard tile pinned on the current Favorites page has its snapshot loaded.
    public void EnsureLoaded(IEnumerable<QuickTile> tiles, bool fresh = false)
    {
        if (_client == null || _pictures == null) return;
        foreach (var t in tiles)
        {
            if (t.Known != QuickTileKind.DashboardTile || Pin(t.Pin) is not { } pin) continue;
            var existing = _pictures.Get(pin.Id);
            if (!fresh && existing != null && (existing.Html != null || existing.Image != null || existing.Gone)) continue;
            _ = ReadAsync(pin, fresh);
        }
    }

    /// Stand-in metadata when a Dashboard tile was unpinned on Dashboard (dimmed card still shows its saved title).
    public static TilePin StandInPin(string id, string name) => new()
    {
        Id = id,
        Kind = TileKind.File,
        Value = name,
        Label = name,
        Title = name,
    };

    /// Builds an embedded Dashboard pin tile card for the Favorites Bento grid.
    public static Button BuildDashboardTile(
        QuickTile tile,
        FavoriteTiles? store,
        bool editing,
        string? missingReason,
        Action onOpen,
        Action onRefresh)
    {
        var pin = store?.Pin(tile.Pin);
        var effectivePin = pin ?? StandInPin(tile.Pin ?? tile.Id, tile.PinName ?? tile.Name);
        var entry = pin != null ? store?.Entry(pin.Id) : null;
        var title = tile.ShownName(pin != null ? store?.Name(pin) : null);
        if (string.IsNullOrWhiteSpace(title)) title = effectivePin.Name;

        var layout = new Grid { RowSpacing = 6 };
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var previewBorder = new Border
        {
            CornerRadius = new CornerRadius(10),
            Background = PageKit.Brush("CardBackgroundFillColorSecondaryBrush"),
            BorderBrush = PageKit.Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
            Child = BuildPreviewVisual(effectivePin, entry, pin == null),
        };
        layout.Children.Add(previewBorder);

        var footer = new Grid { ColumnSpacing = 6 };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var label = new TextBlock
        {
            Text = title,
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            MaxLines = 1,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        footer.Children.Add(label);

        if (!editing && pin != null && pin.IsPage)
        {
            var refresh = new Button
            {
                Content = new FontIcon { Glyph = "\uE72C", FontSize = 11 },
                Width = 22,
                Height = 22,
                Padding = new Thickness(0),
                CornerRadius = new CornerRadius(6),
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
            };
            ToolTipService.SetToolTip(refresh, "Refresh Tile");
            AutomationProperties.SetName(refresh, $"Refresh {title}");
            refresh.Click += (_, _) => onRefresh();
            Grid.SetColumn(refresh, 1);
            footer.Children.Add(refresh);
        }

        Grid.SetRow(footer, 1);
        layout.Children.Add(footer);

        var wrapper = new Grid { Opacity = missingReason == null && pin != null ? 1 : 0.5 };
        wrapper.Children.Add(layout);

        var btn = new Button
        {
            Content = wrapper,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
            Padding = new Thickness(10, 10, 10, 8),
            CornerRadius = new CornerRadius(14),
            Background = PageKit.Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = PageKit.Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetAutomationId(btn, "quick-tile-" + tile.Id);
        AutomationProperties.SetName(btn, $"{title}, Dashboard tile");
        if (missingReason != null || pin == null) AutomationProperties.SetItemStatus(btn, "Unavailable");
        btn.Click += (_, _) => onOpen();
        return btn;
    }

    /// Compact 28×28 thumbnail badge for Add Action picker rows.
    public static FrameworkElement BuildThumb(TilePin pin, FavoriteTiles? store)
    {
        var entry = store?.Entry(pin.Id);
        var host = new Border
        {
            Width = 28,
            Height = 28,
            CornerRadius = new CornerRadius(6),
            Background = PageKit.Brush("CardBackgroundFillColorSecondaryBrush"),
            BorderBrush = PageKit.Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        if (entry?.Image is { Length: > 0 } bytes)
        {
            var img = new Image { Stretch = Stretch.UniformToFill };
            _ = LoadBytesAsync(img, bytes);
            host.Child = img;
        }
        else
        {
            host.Child = new FontIcon
            {
                Glyph = TileCell.Glyph(pin, entry?.Failure != null),
                FontSize = 14,
                Foreground = PageKit.Accent,
            };
        }
        return host;
    }

    private static FrameworkElement BuildPreviewVisual(TilePin pin, TilePictures.Entry? entry, bool missing)
    {
        if (missing)
        {
            return CenterStack("\uE9CE", "Unpinned from Dashboard", PageKit.Secondary);
        }
        if (pin.Kind == TileKind.Image)
        {
            if (TileFiles.IsHosted(pin) && Uri.TryCreate(pin.Value, UriKind.Absolute, out var uri))
                return new Image { Source = new BitmapImage(uri), Stretch = Stretch.UniformToFill };
            if (entry?.Image is { Length: > 0 } bytes)
            {
                var img = new Image { Stretch = Stretch.UniformToFill };
                _ = LoadBytesAsync(img, bytes);
                return img;
            }
        }
        if (pin.IsPage)
        {
            var failed = entry?.Failure != null || entry?.Gone == true;
            var stack = new StackPanel
            {
                Spacing = 4,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(10),
            };
            stack.Children.Add(new FontIcon
            {
                Glyph = TileCell.Glyph(pin, failed),
                FontSize = 24,
                Foreground = failed ? PageKit.Solid(PageKit.Orange) : PageKit.Accent,
            });
            var detail = failed ? (entry?.Failure ?? "Unavailable")
                : entry?.Head?.Title is { Length: > 0 } h ? h
                : entry?.Html != null ? "Live tile · click to open"
                : "Dashboard tile";
            stack.Children.Add(new TextBlock
            {
                Text = detail,
                FontSize = 11.5,
                Foreground = PageKit.Secondary,
                MaxLines = 2,
                TextAlignment = TextAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.WrapWholeWords,
            });
            return stack;
        }
        return CenterStack(TileCell.Glyph(pin, entry?.Failure != null), pin.Label, PageKit.Accent);
    }

    private static StackPanel CenterStack(string glyph, string note, Brush iconBrush) => new()
    {
        Spacing = 4,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(8),
        Children =
        {
            new FontIcon { Glyph = glyph, FontSize = 22, Foreground = iconBrush },
            new TextBlock
            {
                Text = note,
                FontSize = 11,
                Foreground = PageKit.Secondary,
                MaxLines = 2,
                TextAlignment = TextAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.WrapWholeWords,
            },
        },
    };

    private static async Task LoadBytesAsync(Image img, byte[] bytes)
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
            {
                writer.WriteBytes(bytes);
                await writer.StoreAsync();
            }
            stream.Seek(0);
            var bmp = new BitmapImage();
            await bmp.SetSourceAsync(stream);
            img.Source = bmp;
        }
        catch (Exception) { }
    }
}
