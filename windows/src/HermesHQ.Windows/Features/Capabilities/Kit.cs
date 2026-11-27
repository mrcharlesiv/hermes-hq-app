using Hermes.Core.Capabilities;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace HermesHQ.Features.Capabilities;

/// The grouped-list look Capabilities draws with: sections of rows in a card with a small header and footer, as the
/// Mac's inset-grouped lists (App/Capabilities/*, HQSectionLabel / HQSectionFooter). Built in code like the other
/// features' screens; theme resources by their documented names only.
internal static class Kit
{
    public const string Chevron = "", More = "", Search = "", Refresh = "", Add = "", Back = "",
        Check = "", Plug = "", Sparkles = "", Hammer = "", Puzzle = "", Key = "", Bag = "",
        Globe = "", Folder = "", Info = "", Warning = "", Close = "", OpenOut = "", Sort = "";

    public static T Res<T>(string key) => ThemeBrushes.Res<T>(key);
    public static Brush Brush(string key) => Res<Brush>(key);
    public static Brush Primary => Brush("HQLabelBrush");
    public static Brush Secondary => Brush("TextFillColorSecondaryBrush");
    public static Brush Tertiary => Brush("TextFillColorTertiaryBrush");
    public static Brush Accent => Brush("AccentTextFillColorPrimaryBrush");
    public static Brush Critical => Brush("SystemFillColorCriticalBrush");
    public static Brush Caution => Brush("SystemFillColorCautionBrush");
    public static Brush Success => Brush("SystemFillColorSuccessBrush");

    public static TextBlock Text(string text, double size = 14, bool secondary = false, bool bold = false, bool wrap = true, Brush? color = null) => new()
    {
        Text = text, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        Foreground = color ?? (secondary ? Secondary : Primary), IsTextSelectionEnabled = false,
    };

    public static FontIcon Glyph(string glyph, double size = 14, Brush? color = null) => new() { Glyph = glyph, FontSize = size, Foreground = color ?? Primary };

    /// A section: its header in small capitals' place, its rows in one card with hairlines between, its footer.
    public static StackPanel Section(string? header, IEnumerable<UIElement> rows, string? footer = null, UIElement? headerExtra = null, UIElement? footerElement = null)
    {
        var s = new StackPanel { Spacing = 0, Margin = new Thickness(0, 0, 0, 18) };
        if (header != null || headerExtra != null)
        {
            var h = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(14, 0, 0, 6) };
            if (header != null) h.Children.Add(new TextBlock { Text = header, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Secondary });
            if (headerExtra != null) h.Children.Add(headerExtra);
            s.Children.Add(h);
        }
        var list = rows.ToList();
        if (list.Count > 0)
        {
            var card = new StackPanel();
            for (var i = 0; i < list.Count; i++)
            {
                if (i > 0) card.Children.Add(new Rectangle { Height = 1, Fill = Brush("DividerStrokeColorDefaultBrush"), Margin = new Thickness(14, 0, 0, 0) });
                card.Children.Add(list[i]);
            }
            s.Children.Add(new Border
            {
                Child = card, CornerRadius = new CornerRadius(8), Background = Brush("CardBackgroundFillColorDefaultBrush"),
                BorderBrush = Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
            });
        }
        if (footer is { Length: > 0 }) s.Children.Add(new TextBlock { Text = footer, FontSize = 12, Foreground = Secondary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(14, 6, 14, 0) });
        if (footerElement != null) { footerElement.SetValue(FrameworkElement.MarginProperty, new Thickness(14, 6, 14, 0)); s.Children.Add(footerElement); }
        return s;
    }

    /// A row's padding box.
    public static Border Pad(UIElement child, double vertical = 9) => new() { Child = child, Padding = new Thickness(14, vertical, 12, vertical) };

    /// Title, subtitle and a trailing element; clicks as a button when `click` is set.
    public static UIElement Row(string title, string? subtitle = null, UIElement? leading = null, UIElement? trailing = null, Action? click = null,
        bool chevron = false, string? tip = null, bool boldTitle = false, Brush? subtitleColor = null, UIElement? subtitleElement = null, bool mono = false,
        int subtitleLines = 2)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (leading != null) grid.Children.Add(leading);
        var words = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        var t = Text(title, 14, bold: boldTitle);
        if (mono) t.FontFamily = Res<FontFamily>("CodeFont");
        words.Children.Add(t);
        if (subtitleElement != null) words.Children.Add(subtitleElement);
        else if (!string.IsNullOrEmpty(subtitle))
        {
            var sub = Text(subtitle, 12, wrap: false, color: subtitleColor ?? Secondary);
            sub.MaxLines = subtitleLines;
            sub.TextWrapping = TextWrapping.Wrap;
            sub.TextTrimming = TextTrimming.CharacterEllipsis;
            words.Children.Add(sub);
        }
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        var tail = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        if (trailing != null) tail.Children.Add(trailing);
        if (chevron) tail.Children.Add(Glyph(Chevron, 12, Tertiary));
        Grid.SetColumn(tail, 2);
        grid.Children.Add(tail);
        if (tip != null) ToolTipService.SetToolTip(words, tip);
        if (click == null) return Pad(grid);
        // The words and logo click; the trailing control (a switch, a button) keeps its own clicks.
        var hit = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(14, 9, 12, 9),
            CornerRadius = new CornerRadius(0),
        };
        AutomationProperties.SetName(hit, title);
        hit.Click += (_, _) => click();
        return hit;
    }

    /// A trailing switch with its label hidden (the row says what it is).
    public static ToggleSwitch Switch(bool on, string name, Action<bool> changed, bool enabled = true)
    {
        var s = new ToggleSwitch { IsOn = on, OnContent = "", OffContent = "", MinWidth = 0, IsEnabled = enabled, Margin = new Thickness(0, 0, -8, 0) };
        AutomationProperties.SetName(s, name);
        var ready = false;
        s.Loaded += (_, _) => ready = true;
        s.Toggled += (_, _) => { if (ready && s.IsOn != on) changed(s.IsOn); };
        return s;
    }

    /// A row that is a labelled switch ("On for Ivy", "All Tools").
    public static UIElement SwitchRow(string title, bool on, Action<bool> changed, bool enabled = true, string? subtitle = null, bool bold = false) =>
        Row(title, subtitle, trailing: Switch(on, title, changed, enabled), boldTitle: bold);

    public static Button Button(string title, Action click, bool accent = false, bool enabled = true, string? name = null)
    {
        var b = new Button { Content = title, IsEnabled = enabled };
        if (accent) b.Style = Res<Style>("AccentButtonStyle");
        AutomationProperties.SetName(b, name ?? title);
        b.Click += (_, _) => click();
        return b;
    }

    public static HyperlinkButton Link(string title, Action click)
    {
        var b = new HyperlinkButton { Content = title, Padding = new Thickness(0) };
        b.Click += (_, _) => click();
        return b;
    }

    /// A row whose words are a link-coloured action ("See All Apps", "Browse Apps") with a count and a chevron.
    public static UIElement BrowseRow(string title, int? count, Action click, string? name = null)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Text(title, 14, color: Accent));
        var tail = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (count is { } n) tail.Children.Add(Text(n.ToString("N0"), 14, secondary: true));
        tail.Children.Add(Glyph(Chevron, 12, Tertiary));
        Grid.SetColumn(tail, 1);
        grid.Children.Add(tail);
        var b = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(14, 10, 12, 10),
        };
        AutomationProperties.SetName(b, name ?? title);
        b.Click += (_, _) => click();
        return b;
    }

    /// A one-line inline notice (the app has no cross-page toast; notices live where they mean something).
    public static UIElement Notice(string text, string glyph = Info, Brush? tint = null, string? action = null, Action? run = null, Action? close = null)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Glyph(glyph, 16, tint ?? Success));
        var words = new StackPanel { Spacing = 8 };
        words.Children.Add(Text(text, 13));
        if (action != null && run != null) words.Children.Add(new Button { Content = action, HorizontalAlignment = HorizontalAlignment.Left }.Also(b => b.Click += (_, _) => run()));
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        if (close != null)
        {
            var x = new Button { Content = Glyph(Close, 10), Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), VerticalAlignment = VerticalAlignment.Top };
            AutomationProperties.SetName(x, "Close");
            ToolTipService.SetToolTip(x, "Close");
            x.Click += (_, _) => close();
            Grid.SetColumn(x, 2);
            grid.Children.Add(x);
        }
        return Pad(grid, 10);
    }

    public static T Also<T>(this T value, Action<T> act) { act(value); return value; }

    /// "Couldn’t Load Skills", the reason and Try Again.
    public static UIElement LoadError(string title, string reason, Action retry)
    {
        var s = new StackPanel { Spacing = 6 };
        s.Children.Add(Text(title, 15, bold: true));
        s.Children.Add(Text(reason, 13, secondary: true));
        s.Children.Add(new Button { Content = "Try Again", Margin = new Thickness(0, 4, 0, 0) }.Also(b => b.Click += (_, _) => retry()));
        return Section(null, [Pad(s, 12)]);
    }

    public static UIElement Plain(string text, bool secondary = true) => Pad(Text(text, 14, secondary: secondary), 12);

    public static UIElement Skeletons(int n = 3, string? header = null) =>
        Section(header, Enumerable.Range(0, n).Select(_ =>
        {
            var s = new StackPanel { Spacing = 8 };
            s.Children.Add(new Rectangle { Width = 120, Height = 14, RadiusX = 6, RadiusY = 6, Fill = Brush("SubtleFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Left });
            s.Children.Add(new Rectangle { Height = 11, RadiusX = 6, RadiusY = 6, Fill = Brush("SubtleFillColorSecondaryBrush") });
            AutomationProperties.SetAccessibilityView(s, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            return (UIElement)Pad(s, 12);
        }));

    public static UIElement Busy(string words)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        s.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        s.Children.Add(Text(words, 14, secondary: true));
        return Pad(s, 10);
    }

    // ---------------------------------------------------------------- Connector look (ConnectorLook.swift)

    public static Brush DotBrush(ConnectorTone tone) => tone switch
    {
        ConnectorTone.Good => Success,
        ConnectorTone.Warn => Caution,
        ConnectorTone.Bad => Critical,
        _ => Tertiary,
    };

    public static Brush WordsBrush(ConnectorTone tone) => tone switch
    {
        ConnectorTone.Warn => Caution,
        ConnectorTone.Bad => Critical,
        _ => Secondary,
    };

    /// "● 5 tools", the dot in the tone's colour.
    public static UIElement StatusLine(string words, ConnectorTone tone, string? spoken = null)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        s.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = DotBrush(tone), VerticalAlignment = VerticalAlignment.Center });
        s.Children.Add(Text(words, 12, color: WordsBrush(tone), wrap: false));
        AutomationProperties.SetName(s, spoken ?? words);
        return s;
    }

    /// The state as a small pill (the connector page's header).
    public static UIElement Badge(string words, ConnectorTone tone)
    {
        var tint = tone is ConnectorTone.Quiet or ConnectorTone.Busy ? Secondary : DotBrush(tone);
        return new Border
        {
            Child = Text(words, 11, bold: true, color: tint, wrap: false), Padding = new Thickness(8, 2, 8, 2), CornerRadius = new CornerRadius(10),
            Background = Brush("SubtleFillColorSecondaryBrush"),
        };
    }

    /// A rounded tile with a symbol (an app with no logo).
    public static UIElement Tile(string glyph, double size = 34) => new Border
    {
        Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.24), Background = Brush("SubtleFillColorSecondaryBrush"),
        Child = Glyph(glyph, size * 0.46, Secondary).Also(g => { g.HorizontalAlignment = HorizontalAlignment.Center; g.VerticalAlignment = VerticalAlignment.Center; }),
    };

    /// `ConnectorSymbol.of`: a symbol for a connector by the words in its name.
    public static string SymbolFor(string name)
    {
        var lower = name.ToLowerInvariant();
        var tokens = System.Text.RegularExpressions.Regex.Split(lower, "[^\\p{L}\\p{N}]+").Where(t => t.Length > 0).ToArray();
        bool Has(string w) => w.Length > 4 ? lower.Contains(w) : tokens.Any(t => t.StartsWith(w) || t.EndsWith(w));
        (string, string)[] words =
        [
            ("browser", Globe), ("chrome", Globe), ("web", Globe), ("fetch", ""), ("file", Folder), ("drive", Folder), ("memory", ""),
            ("terminal", ""), ("shell", ""), ("git", ""), ("sql", ""), ("postgres", ""), ("database", ""),
            ("db", ""), ("time", ""), ("calendar", ""), ("mail", ""), ("search", Search), ("map", ""),
            ("weather", ""), ("image", ""), ("photo", ""), ("voice", ""), ("audio", ""), ("note", ""), ("think", ""),
        ];
        return words.FirstOrDefault(p => Has(p.Item1)).Item2 ?? Plug;
    }

    /// A logo from the web (an app's `logo_url`), the symbol tile while it loads and when it can't.
    public static UIElement Logo(string? url, string name, double size = 34)
    {
        var tile = Tile(SymbolFor(name), size);
        if (url == null || !Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != "https") return tile;
        var grid = new Grid { Width = size, Height = size };
        grid.Children.Add(tile);
        ImageSource source = uri.AbsolutePath.EndsWith(".svg", StringComparison.OrdinalIgnoreCase)
            ? new SvgImageSource(uri) { RasterizePixelWidth = size * 2, RasterizePixelHeight = size * 2 }
            : new BitmapImage(uri) { DecodePixelWidth = (int)(size * 2) };
        var image = new Image { Source = source, Stretch = Stretch.Uniform, Margin = new Thickness(size * 0.12) };
        var face = new Border { CornerRadius = new CornerRadius(size * 0.24), Background = new SolidColorBrush(Colors.White), Child = image, Opacity = 0 };
        if (source is BitmapImage b)
        {
            b.ImageOpened += (_, _) => face.Opacity = 1;
            b.ImageFailed += (_, _) => grid.Children.Remove(face);
        }
        else if (source is SvgImageSource svg)
        {
            svg.Opened += (_, _) => face.Opacity = 1;
            svg.OpenFailed += (_, _) => grid.Children.Remove(face);
        }
        grid.Children.Add(face);
        return grid;
    }

    /// The connector page's header card: logo, name, state badge, kind, description.
    public static UIElement Header(string title, UIElement logo, (string Words, ConnectorTone Tone)? state, string? kind, string description = "")
    {
        var top = new Grid { ColumnSpacing = 14 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.Children.Add(logo);
        var words = new StackPanel { Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(Text(title, 20, bold: true));
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (state is { } s) line.Children.Add(Badge(s.Words, s.Tone));
        if (kind != null) line.Children.Add(Text(kind, 12, secondary: true, wrap: false).Also(t => t.VerticalAlignment = VerticalAlignment.Center));
        if (line.Children.Count > 0) words.Children.Add(line);
        Grid.SetColumn(words, 1);
        top.Children.Add(words);
        var all = new StackPanel { Spacing = 10 };
        all.Children.Add(top);
        if (description.Length > 0) all.Children.Add(Text(description, 13, secondary: true));
        return Section(null, [Pad(all, 12)]);
    }

    // ---------------------------------------------------------------- Dialogs

    public static async Task<ContentDialogResult> Show(XamlRoot? root, ContentDialog dialog)
    {
        if (root == null) return ContentDialogResult.None;
        dialog.XamlRoot = root;
        try { return await dialog.ShowAsync(); }
        catch (Exception x) when (x is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            AppLog.Note("capabilities", "a dialog was already open");
            return ContentDialogResult.None;
        }
    }

    /// The Mac's FailureAlert: the title, the reason, OK (and Try Again when it can be retried).
    public static async void Fail(XamlRoot? root, string title, string reason, Action? retry = null)
    {
        var d = new ContentDialog
        {
            Title = title, Content = Text(reason, 14), CloseButtonText = "OK", DefaultButton = ContentDialogButton.Close,
            PrimaryButtonText = retry != null ? "Try Again" : "",
        };
        if (await Show(root, d) == ContentDialogResult.Primary) retry?.Invoke();
    }

    /// TextPrompt.confirm: the title, the words, the action (red when it removes) and Cancel.
    public static async Task<bool> Confirm(XamlRoot? root, string title, string? message, string action, bool destructive = false)
    {
        var d = new ContentDialog
        {
            Title = title, Content = message is { Length: > 0 } ? Text(message, 14) : null, PrimaryButtonText = action, CloseButtonText = "Cancel",
            DefaultButton = destructive ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        if (destructive) d.PrimaryButtonStyle = new Style(typeof(Button)).Also(s =>
        {
            s.BasedOn = Res<Style>("DefaultButtonStyle");
            s.Setters.Add(new Setter(Control.ForegroundProperty, Critical));
        });
        return await Show(root, d) == ContentDialogResult.Primary;
    }

    public static async void Open(string url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var u))
        {
            try { await Launcher.LaunchUriAsync(u); } catch (Exception) { }
        }
    }

    public static void Copy(string text) => HermesHQ.Services.SafeClipboard.TrySetText(text);

    public static async Task<string?> Paste()
    {
        try
        {
            var view = Clipboard.GetContent();
            return view.Contains(StandardDataFormats.Text) ? (await view.GetTextAsync()).Trim() : null;
        }
        catch (Exception) { return null; }
    }

    public static MenuFlyoutItem Item(string text, string? glyph, Action click, bool enabled = true)
    {
        var i = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        if (glyph != null) i.Icon = new FontIcon { Glyph = glyph };
        i.Click += (_, _) => click();
        return i;
    }

    public static ToggleMenuFlyoutItem CheckItem(string text, bool on, Action click, bool enabled = true)
    {
        var i = new ToggleMenuFlyoutItem { Text = text, IsChecked = on, IsEnabled = enabled };
        i.Click += (_, _) => click();
        return i;
    }

    /// A small "Get" / "Install" button at a row's end.
    public static Button RowAction(string title, Action click, string? name = null)
    {
        var b = new Button { Content = title, Padding = new Thickness(12, 3, 12, 4), FontWeight = FontWeights.SemiBold, CornerRadius = new CornerRadius(12) };
        AutomationProperties.SetName(b, name ?? title);
        b.Click += (_, _) => click();
        return b;
    }

    public static UIElement Spinner(double size = 16) => new ProgressRing { IsActive = true, Width = size, Height = size };

    /// Whether this sign-in link may open (https; the stand-in gateway's loopback http too).
    public static Uri? SafeLink(string link)
    {
        if (!Uri.TryCreate(link, UriKind.Absolute, out var u)) return null;
        if (u.Scheme == "https") return u;
        return u.Scheme == "http" && u.Host is "127.0.0.1" or "localhost" ? u : null;
    }

}
