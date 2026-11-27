using System.Runtime.InteropServices.WindowsRuntime;
using Hermes.Core;
using Hermes.Core.Heads;
using Hermes.Core.Model;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace HermesHQ.Features.Heads;

/// Edit Head (App/Heads/EditHeadView.swift, spec 1x-settings §7) as a dialog: the draft head stays in view at the top
/// with Shuffle and Undo; below it Describe it, the themes (each a picture of this bot in it), ten ideas for this bot,
/// the theme's own parts (strips of the draft with one part changed), its colours, extras, My Style and Reset Head.
/// Save is compare-and-swap; the new head shows everywhere at once and a 288 × 288 copy goes to desktop Hermes.
public sealed class EditHeadDialog
{
    readonly EditHeadModel _model;
    readonly HermesClient _client;
    readonly ContentDialog _dialog;
    readonly StackPanel _top = new() { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Stretch };
    readonly StackPanel _body = new() { Spacing = 22, Padding = new Thickness(0, 0, 12, 12) };
    readonly TextBox _describe;
    readonly TextBlock _understood = Footnote("");
    readonly TextBox _glyph;
    // The typing fields stay put while the rest is rebuilt round them, so a keystroke never loses focus.
    readonly StackPanel _notice = new();
    readonly StackPanel _partsA = new() { Spacing = 22 };
    readonly StackPanel _partsB = new() { Spacing = 22 };
    readonly StackPanel _glyphSection;
    readonly Canvas _mirrorHost = new() { Width = 0, Height = 0 };
    bool _reset;
    bool _building;

    static string StylePath => Path.Combine(AppPaths.Root, "head-style.json");

    EditHeadDialog(Bot bot, HermesClient client, XamlRoot root)
    {
        _client = client;
        _model = new EditHeadModel(bot, HeadStore.State(bot),
            () => File.Exists(StylePath) ? File.ReadAllText(StylePath) : null,
            json => { Directory.CreateDirectory(AppPaths.Root); File.WriteAllText(StylePath, json); });
        _describe = new TextBox { PlaceholderText = "sleepy purple cat with goggles", IsSpellCheckEnabled = false };
        AutomationProperties.SetName(_describe, "Describe it");
        _describe.TextChanged += (_, _) => { if (!_building) _model.Describe(_describe.Text); };
        _glyph = new TextBox { PlaceholderText = "✨", MaxLength = 16, FontSize = 20 };
        AutomationProperties.SetName(_glyph, "Emoji or Letters");
        _glyph.TextChanged += (_, _) =>
        {
            if (_building) return;
            var text = _glyph.Text;
            if (text.Trim().Length == 0 || HeadRecord.CleanGlyph(text) == _model.Draft.Glyph) return;
            _model.Set(h => h.Glyph = HeadRecord.CleanGlyph(text));
        };
        _glyphSection = Section("Emoji or Letters", null, _glyph);
        _body.Children.Add(_notice);
        _body.Children.Add(Section("Describe it", null, _describe, _understood));
        _body.Children.Add(_partsA);
        _body.Children.Add(_glyphSection);
        _body.Children.Add(_partsB);
        _dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = "Edit Head",
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
            Content = new Grid
            {
                MinWidth = 460,
                RowDefinitions = { new RowDefinition { Height = GridLength.Auto }, new RowDefinition { Height = new GridLength(1, GridUnitType.Star) } },
                Children = { _top, _mirrorHost },
            },
        };
        var scroller = new ScrollViewer { Content = _body, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroller, 1);
        ((Grid)_dialog.Content).Children.Add(scroller);
        _dialog.PrimaryButtonClick += OnSave;
        _model.Changed += Rebuild;
        Rebuild();
    }

    /// Shows Edit Head for `bot`. True when a head was saved or reset.
    public static async Task<bool> ShowAsync(Bot bot, HermesClient client, XamlRoot root)
    {
        var dialog = new EditHeadDialog(bot, client, root);
        var result = await HermesHQ.Services.SafeDialog.ShowAsync(root, dialog._dialog);
        return result == ContentDialogResult.Primary || dialog._reset;
    }

    RpcCall Rpc => _client.Rpc.RequestAsync;

    async void OnSave(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (!_model.HasChanges || _model.Saving) { args.Cancel = true; return; }
        var deferral = args.GetDeferral();
        try
        {
            var saved = await _model.SaveAsync(Rpc, _model.Draft, MirrorPngAsync);
            args.Cancel = !saved;
        }
        catch (Exception ex)
        {
            args.Cancel = true;
            HermesHQ.Services.AppLog.Error("heads", ex);
        }
        finally { deferral.Complete(); }
    }

    async void OnReset()
    {
        if (_model.Saving) return;
        try
        {
            if (await _model.SaveAsync(Rpc, null))
            {
                // Reset Head stays confirm-free, as the web.
                _reset = true;
                _dialog.Hide();
            }
        }
        catch (Exception ex) { HermesHQ.Services.AppLog.Error("heads", ex); }
    }

    // MARK: Building

    void Rebuild()
    {
        _building = true;
        try
        {
            var m = _model;
            _dialog.PrimaryButtonText = m.Saving ? "Saving…" : "Save";
            _dialog.IsPrimaryButtonEnabled = m.HasChanges && !m.Saving;
            _body.IsHitTestVisible = !m.Saving;

            // The stage: the draft under the title, with Shuffle and Undo.
            _top.Children.Clear();
            var stage = new HeadFace(m.Draft.Head, 96) { HorizontalAlignment = HorizontalAlignment.Center };
            AutomationProperties.SetName(stage, $"{m.Bot.Name}’s head");
            AutomationProperties.SetHelpText(stage, HeadLabels.Describe(m.Draft));
            _top.Children.Add(stage);
            if (m.OtherTheme is { } theme)
                _top.Children.Add(Center(Footnote($"This bot wears a {theme} head, which Hermes HQ no longer draws. Saving makes it a Shapes head.")));
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 24, HorizontalAlignment = HorizontalAlignment.Center };
            actions.Children.Add(Plain("Shuffle", () => m.Shuffle()));
            var undo = Plain("Undo", m.UndoLast);
            undo.IsEnabled = m.Undo != null;
            actions.Children.Add(undo);
            _top.Children.Add(actions);

            _notice.Children.Clear();
            if (m.Notice is { } notice)
            {
                _notice.Children.Add(new TextBlock
                {
                    Text = notice, TextWrapping = TextWrapping.Wrap,
                    Foreground = Res("SystemFillColorCriticalBrush") ?? new SolidColorBrush(Colors.Red),
                });
            }
            _understood.Text = m.UnderstoodWords ?? "";
            _understood.Visibility = m.UnderstoodWords == null ? Visibility.Collapsed : Visibility.Visible;
            _partsA.Children.Clear();
            _partsA.Children.Add(Themes());
            _partsA.Children.Add(Ideas());
            foreach (var strip in m.Strips) _partsA.Children.Add(Strip(strip.Title, strip.Options, strip.Names, strip.Field));
            _glyphSection.Visibility = m.Draft.Theme == "glyph" ? Visibility.Visible : Visibility.Collapsed;
            if (m.Draft.Theme == "glyph" && HeadRecord.CleanGlyph(_glyph.Text) != m.Draft.Glyph) _glyph.Text = m.Draft.Glyph;
            _partsB.Children.Clear();
            _partsB.Children.Add(Colours());
            if (m.Draft.Theme != "matrix") _partsB.Children.Add(Extras());
            _partsB.Children.Add(MyStyle());
            if (m.Opened.Saved)
            {
                var reset = new Button { Content = "Reset Head", Foreground = Res("SystemFillColorCriticalBrush") };
                reset.Click += (_, _) => OnReset();
                _partsB.Children.Add(reset);
            }
        }
        finally { _building = false; }
    }

    UIElement Themes()
    {
        var grid = Columns(4);
        foreach (var (theme, index) in HeadLabels.OfferedThemes.Select((t, i) => (t, i)))
        {
            var selected = _model.Draft.Theme == theme;
            var content = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
            content.Children.Add(new HeadFace((selected ? _model.Draft : EditHeadModel.Themed(_model.Draft, theme)).Head, 60));
            content.Children.Add(new TextBlock
            {
                Text = HeadLabels.Name(HeadLabels.Themes, theme), HorizontalAlignment = HorizontalAlignment.Center, FontSize = 13,
                FontWeight = FontWeights.Medium, Foreground = selected ? Res("AccentTextFillColorPrimaryBrush") : Res("TextFillColorPrimaryBrush"),
            });
            var tile = Tile(content, selected, () => _model.PickTheme(theme));
            AutomationProperties.SetName(tile, HeadLabels.Name(HeadLabels.Themes, theme));
            Place(grid, tile, index, 4);
        }
        return Section("Theme", null, grid);
    }

    UIElement Ideas()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        foreach (var (idea, index) in _model.Ideas.Select((h, i) => (h, i)))
        {
            var tile = Tile(new HeadFace(idea.Head, 56), false, () => _model.SetWhole(idea));
            AutomationProperties.SetName(tile, $"Idea {index + 1}: {HeadLabels.Summary(idea)}");
            row.Children.Add(tile);
        }
        return Section($"Ideas for {_model.Bot.Name}", null, Scroller(row));
    }

    UIElement Strip(string title, string[] options, Dictionary<string, string> names, string field)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        var current = EditHeadModel.Field(_model.Draft, field);
        foreach (var option in options)
        {
            var tile = Tile(new HeadFace(EditHeadModel.With(_model.Draft, field, option).Head, 56), current == option,
                () => _model.Set(h => EditHeadModel.Assign(h, field, option)));
            AutomationProperties.SetName(tile, HeadLabels.Name(names, option));
            row.Children.Add(tile);
        }
        return Section(title, names.GetValueOrDefault(current), Scroller(row));
    }

    UIElement Colours()
    {
        var grid = Columns(6);
        var palette = _model.Palette;
        var own = HeadRecord.Offered(_model.Draft.Color);
        for (var i = 0; i < palette.Length; i++)
        {
            var colour = palette[i];
            var swatch = new Microsoft.UI.Xaml.Shapes.Ellipse
            {
                Width = 38, Height = 38, Fill = HeadDrawing.Brush(HeadTones.Swatch(colour)),
                Stroke = colour == "paper" ? Res("ControlStrokeColorDefaultBrush") : null, StrokeThickness = 1,
            };
            var ring = new Border
            {
                Padding = new Thickness(4), CornerRadius = new CornerRadius(25), Child = swatch, BorderThickness = new Thickness(2.5),
                BorderBrush = own == colour ? Res("AccentFillColorDefaultBrush") : new SolidColorBrush(Colors.Transparent),
            };
            var button = new Button
            {
                Content = ring, Padding = new Thickness(0), Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Center,
            };
            button.Click += (_, _) => _model.Set(h => h.Color = colour);
            AutomationProperties.SetName(button, HeadLabels.Name(HeadLabels.Colors, colour));
            Place(grid, button, i, 6);
        }
        return Section("Color", HeadLabels.Colors.GetValueOrDefault(_model.Draft.Color), grid);
    }

    UIElement Extras()
    {
        var d = _model.Draft;
        var card = new StackPanel { Spacing = 12 };
        switch (d.Theme)
        {
            case "robot":
                card.Children.Add(Choice("Antenna", HeadRecord.Antennas, HeadLabels.Antennas, d.Antenna, v => _model.Set(h => h.Antenna = v)));
                card.Children.Add(Choice("Ears", HeadRecord.Ears, HeadLabels.Ears, d.EarsKind, v => _model.Set(h => h.EarsKind = v)));
                break;
            case "shape":
                card.Children.Add(Choice("Backdrop", ["none", "dark", "light", "color"], HeadLabels.Tiles, d.Tile, v => _model.Set(h => h.Tile = v)));
                if (d.Form == "blob") card.Children.Add(Remix("New Blob"));
                break;
            default:
                card.Children.Add(Choice("Tile", ["dark", "light", "color"], HeadLabels.Tiles, d.Tile, v => _model.Set(h => h.Tile = v)));
                if (d.Theme == "orb" || (d.Theme == "dots" && d.Pattern is "ring" or "bloom"))
                    card.Children.Add(Choice("Eyes", ["off", "on"], new() { ["off"] = "Off", ["on"] = "On" }, d.Eyes ? "on" : "off",
                        v => _model.Set(h => h.Eyes = v == "on")));
                if (d.Theme == "pixel") card.Children.Add(Remix("New Creature"));
                if (d.Theme == "orb") card.Children.Add(Remix("New Light"));
                if (d.Theme == "dots" && d.Pattern != "face") card.Children.Add(Remix("New Pattern"));
                break;
        }
        return Section("Extras", null, Card(card));
    }

    UIElement MyStyle()
    {
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var set = new Button { Content = "Set as My Style" };
        set.Click += (_, _) => _model.SetStyle();
        var use = new Button { Content = "Use My Style", IsEnabled = _model.Style != null };
        use.Click += (_, _) => _model.UseStyle();
        buttons.Children.Add(set);
        buttons.Children.Add(use);
        return Section("My Style", null, Footnote("Keep one look for all your bots. Each bot keeps its own color."), buttons);
    }

    // MARK: Pieces

    /// A labelled segmented choice (the Mac's segments): one toggle per option, the current one on.
    static UIElement Choice(string title, string[] options, Dictionary<string, string> names, string current, Action<string> set)
    {
        var row = new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        row.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });
        var segments = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var option in options)
        {
            var toggle = new ToggleButton { Content = HeadLabels.Name(names, option), IsChecked = option == current, MinWidth = 52 };
            toggle.Click += (_, _) => set(option);
            segments.Children.Add(toggle);
        }
        AutomationProperties.SetName(segments, title);
        Grid.SetColumn(segments, 1);
        row.Children.Add(segments);
        return row;
    }

    UIElement Remix(string label)
    {
        var row = new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        row.Children.Add(new TextBlock { Text = "Remix", VerticalAlignment = VerticalAlignment.Center });
        var button = Plain(label, () => _model.Remix());
        Grid.SetColumn(button, 1);
        row.Children.Add(button);
        return row;
    }

    static StackPanel Section(string title, string? value, params UIElement[] content)
    {
        var heading = new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        heading.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, Foreground = Res("TextFillColorSecondaryBrush") });
        if (value != null)
        {
            var v = new TextBlock { Text = value, Foreground = Res("TextFillColorSecondaryBrush") };
            Grid.SetColumn(v, 1);
            heading.Children.Add(v);
        }
        var section = new StackPanel { Spacing = 8 };
        section.Children.Add(heading);
        foreach (var c in content) section.Children.Add(c);
        return section;
    }

    static Button Tile(UIElement content, bool selected, Action click)
    {
        var button = new Button
        {
            Content = content, Padding = new Thickness(6), CornerRadius = new CornerRadius(14),
            Background = Res("CardBackgroundFillColorDefaultBrush"), HorizontalAlignment = HorizontalAlignment.Stretch,
            BorderThickness = new Thickness(2.5),
            BorderBrush = selected ? Res("AccentFillColorDefaultBrush") : new SolidColorBrush(Colors.Transparent),
        };
        button.Click += (_, _) => click();
        return button;
    }

    static ButtonBase Plain(string label, Action click)
    {
        var button = new HyperlinkButton { Content = label, FontWeight = FontWeights.Medium };
        button.Click += (_, _) => click();
        return button;
    }

    static Border Card(UIElement content) => new()
    {
        Child = content, Padding = new Thickness(16), CornerRadius = new CornerRadius(16), Background = Res("CardBackgroundFillColorDefaultBrush"),
    };

    static ScrollViewer Scroller(UIElement content) => new()
    {
        Content = content, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollMode = ScrollMode.Disabled, Padding = new Thickness(0, 2, 0, 8),
    };

    static Grid Columns(int count)
    {
        var grid = new Grid { ColumnSpacing = 10, RowSpacing = 10 };
        for (var i = 0; i < count; i++) grid.ColumnDefinitions.Add(new ColumnDefinition());
        return grid;
    }

    static void Place(Grid grid, FrameworkElement child, int index, int columns)
    {
        while (grid.RowDefinitions.Count <= index / columns) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(child, index / columns);
        Grid.SetColumn(child, index % columns);
        grid.Children.Add(child);
    }

    static TextBlock Footnote(string text) => new()
    {
        Text = text, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Res("TextFillColorSecondaryBrush"),
    };

    static UIElement Center(FrameworkElement e)
    {
        e.HorizontalAlignment = HorizontalAlignment.Center;
        if (e is TextBlock t) t.TextAlignment = TextAlignment.Center;
        return e;
    }

    static Brush? Res(string key) =>
        Application.Current.Resources.TryGetValue(key, out var value) ? value as Brush : null;

    // MARK: The desktop copy

    /// The saved head drawn 288 × 288 for no page in particular, as a PNG (`mirrorPNG`). Best effort: null when it
    /// can't be drawn here.
    async Task<byte[]?> MirrorPngAsync(Head head)
    {
        var side = (double)HeadRecord.MirrorSize;
        var face = new HeadFace(head, side, pageUnknown: true);
        Canvas.SetLeft(face, -4000);
        _mirrorHost.Children.Add(face);
        try
        {
            await Task.Delay(head.Themed != null || head.Theme == HeadTheme.Matrix ? 400 : 60);
            var bitmap = new RenderTargetBitmap();
            await bitmap.RenderAsync(face, HeadRecord.MirrorSize, HeadRecord.MirrorSize);
            var pixels = (await bitmap.GetPixelsAsync()).ToArray();
            using var stream = new InMemoryRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
            encoder.BitmapTransform.ScaledWidth = (uint)HeadRecord.MirrorSize;
            encoder.BitmapTransform.ScaledHeight = (uint)HeadRecord.MirrorSize;
            encoder.BitmapTransform.InterpolationMode = BitmapInterpolationMode.Fant;
            await encoder.FlushAsync();
            var bytes = new byte[stream.Size];
            stream.Seek(0);
            await stream.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
            return bytes;
        }
        catch (Exception e)
        {
            AppLog.Error("heads", e);
            return null;
        }
        finally
        {
            _mirrorHost.Children.Remove(face);
        }
    }
}
