using Hermes.Core.Transcripts;
using Hermes.Core.Settings;
using HermesHQ.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace HermesHQ.Features.Transcript;

/// A link chip (App/Chat/Cells/LinkChipView.swift; docs/spec/3x-transcript.md §3.7): a bare web address alone on its own
/// paragraph of a settled reply gets a card in its place with the site's icon, the page's title and the host. Its size is
/// fixed from the start, so a title or icon that arrives later never moves the transcript. The title and icon come from
/// one bounded, cookieless https read made from this PC (`LinkPreviews`), only for chips that are on screen (loaded).
public sealed class LinkChipView : HyperlinkButton
{
    public const double IconSize = LinkChipSize.IconSize;   // the Mac's 18, whatever the text size
    public const double PadH = LinkChipSize.PadH, PadV = LinkChipSize.PadV;
    public const double TitleSize = LinkChipSize.TitleSize, HostSize = LinkChipSize.HostSize;   // the transcript's body and time sizes
    /// [WIN-LINK-CHIP-SCALE] padV + body line + 2 + time line + padV, as the Mac's `height(style:)`: the lines follow
    /// Windows' text size (TextScaleFactor) as the Mac's follow its text size. Fixed while that stays put.
    private double ChipHeight => LinkChipSize.Height(_textScale);
    /// [WIN-LINK-CHIP-FIT] The Mac's `width(maxText:)` cap; UI Scale already scales it with the window (LinkChipFit).
    public const double MaxChipWidth = LinkChipFit.MaxWidth;

    private readonly string _raw;
    private readonly Uri _url;
    private readonly Border _card;
    private readonly Border _iconBox;
    private readonly TextBlock _title, _host;
    private bool _onScreen;
    private bool _answered;
    /// Windows' text size (Settings › Accessibility › Text size), read when made and again when it changes.
    private double _textScale = ReadTextScale();
    /// The whole host (LinkChips.Face); the line shows it cut in the middle to fit, as the Mac's `.byTruncatingMiddle`.
    private string _hostWhole = "";
    private readonly TextBlock _hostMeasure = new() { FontSize = HostSize, TextWrapping = TextWrapping.NoWrap };

    public LinkChipView(ChipSegment chip)
    {
        _raw = chip.Raw;
        _url = chip.Url;
        Padding = new Thickness(0);
        Margin = new Thickness(0, 6, 0, 8);
        HorizontalAlignment = HorizontalAlignment.Left;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
        // No fixed Width: MeasureOverride takes the reply column's room, up to the cap, so a narrow reply keeps the card
        // inside it. Its height stays fixed from the start.
        Height = ChipHeight;
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        AutomationProperties.SetAutomationId(this, LinkChips.AutomationId);

        _title = new TextBlock
        {
            FontSize = TitleSize, LineHeight = LinkChipSize.TitleLine(_textScale), TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap,
            Foreground = Res<Brush>("TextFillColorPrimaryBrush"), VerticalAlignment = VerticalAlignment.Center,
        };
        _host = new TextBlock
        {
            FontSize = HostSize, LineHeight = LinkChipSize.HostLine(_textScale), TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap,
            Foreground = Res<Brush>("TextFillColorSecondaryBrush"), Margin = new Thickness(0, 2, 0, 0),
        };
        // The chip's name says it all once: its words aren't read again on their own.
        AutomationProperties.SetAccessibilityView(_title, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_host, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        _iconBox = new Border { Width = IconSize, Height = IconSize, CornerRadius = new CornerRadius(4), VerticalAlignment = VerticalAlignment.Center };

        var grid = new Grid { VerticalAlignment = VerticalAlignment.Center, ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(IconSize) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetColumn(_title, 1);
        Grid.SetColumn(_host, 1);
        Grid.SetRow(_host, 1);
        grid.Children.Add(_iconBox);
        grid.Children.Add(_title);
        grid.Children.Add(_host);
        _card = new Border
        {
            Child = grid,
            Padding = new Thickness(PadH, 0, PadH, 0),
            CornerRadius = new CornerRadius(12),
            Background = Res<Brush>("SubtleFillColorSecondaryBrush"),
            BorderBrush = Res<Brush>("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        Content = _card;

        // Lit under the pointer, as the Mac's surfaces.
        PointerEntered += (_, _) => _card.Background = Res<Brush>("SubtleFillColorTertiaryBrush");
        PointerExited += (_, _) => _card.Background = Res<Brush>("SubtleFillColorSecondaryBrush");
        Click += (_, _) => ChatLinks.Open(_url);

        // Before any read: where it goes, in words (host and path; "…" for a query it leaves out).
        Show(LinkPreviews.Shared.Known(_raw));
        Loaded += OnLoaded;
        Unloaded += (_, _) =>
        {
            _onScreen = false;
            TextSize.Changed -= OnTextScaleChanged;
        };
        SizeChanged += (_, _) => FitHost();
    }

    /// [WIN-LINK-CHIP-SCALE] One UISettings for every chip, held so its TextScaleFactorChanged keeps firing.
    private static class TextSize
    {
        private static readonly Windows.UI.ViewManagement.UISettings? Settings = Make();
        public static event Action? Changed;

        public static double Factor
        {
            get
            {
                try { return Settings?.TextScaleFactor ?? 1; }
                catch (System.Runtime.InteropServices.COMException) { return 1; }
            }
        }

        private static Windows.UI.ViewManagement.UISettings? Make()
        {
            try
            {
                var settings = new Windows.UI.ViewManagement.UISettings();
                settings.TextScaleFactorChanged += OnSystemTextScaleChanged;
                return settings;
            }
            catch (System.Runtime.InteropServices.COMException) { return null; }
        }

        private static void OnSystemTextScaleChanged(Windows.UI.ViewManagement.UISettings sender, object args)
        {
            if (!Services.AppShutdown.Stopping) Changed?.Invoke();
        }

        internal static void StopForQuit()
        {
            if (Settings != null) Settings.TextScaleFactorChanged -= OnSystemTextScaleChanged;
            Changed = null;
        }
    }

    internal static void StopForQuit() => TextSize.StopForQuit();

    private static double ReadTextScale() => TextSize.Factor;

    // Raised off the UI thread: the chip refits on its own.
    private void OnTextScaleChanged()
    {
        if (Services.AppShutdown.Stopping || !_onScreen) return;
        DispatcherQueue?.TryEnqueue(ApplyTextScale);
    }

    /// The text size changed: the lines and the height follow it (the icon and the width don't, as the Mac's).
    private void ApplyTextScale()
    {
        if (Services.AppShutdown.Stopping || !_onScreen) return;
        var next = ReadTextScale();
        if (Math.Abs(next - _textScale) < 0.001) return;
        _textScale = next;
        _title.LineHeight = LinkChipSize.TitleLine(_textScale);
        _host.LineHeight = LinkChipSize.HostLine(_textScale);
        Height = ChipHeight;
        InvalidateMeasure();
        FitHost();
    }

    /// The host line cut in the middle to the words' room beside the icon (the Mac's `.byTruncatingMiddle`), from the
    /// whole host each time, so a wider card gets it back.
    private void FitHost()
    {
        var room = LinkChipSize.TextRoom(ActualWidth);
        if (room <= 0 || _hostWhole.Length == 0) { _host.Text = _hostWhole; return; }
        // A unit short of the room: the line's own tail ellipsis never cuts what was already cut in the middle.
        var text = LinkChipSize.MiddleTrim(_hostWhole, room - 1, MeasureHost);
        if (_host.Text != text) _host.Text = text;
    }

    private double MeasureHost(string text)
    {
        _hostMeasure.Text = text;
        _hostMeasure.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        return _hostMeasure.DesiredSize.Width;
    }

    /// [WIN-LINK-CHIP-FIT] The room the reply's column offers (after this chip's margin), up to the cap, as the Mac's
    /// `width(maxText:)`. The title never decides it, so a title arriving later can't move the reply; a column that
    /// narrows measures again and the card follows. The window's UI Scale transform scales it once, outside.
    protected override Windows.Foundation.Size MeasureOverride(Windows.Foundation.Size available)
    {
        var size = new Windows.Foundation.Size(LinkChipFit.Width(available.Width), ChipHeight);
        base.MeasureOverride(size);
        return size;
    }

    protected override Windows.Foundation.Size ArrangeOverride(Windows.Foundation.Size final)
    {
        var size = new Windows.Foundation.Size(LinkChipFit.Width(final.Width), ChipHeight);
        base.ArrangeOverride(size);
        return size;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        _onScreen = true;
        TextSize.Changed -= OnTextScaleChanged;
        TextSize.Changed += OnTextScaleChanged;
        ApplyTextScale();   // changed while it was off screen
        if (_answered) return;
        var preview = await LinkPreviews.Shared.PreviewAsync(_raw);
        // A chip scrolled away meanwhile keeps its words; the answer is cached for when it is back.
        if (!_onScreen || preview == null) return;
        Show(preview);
    }

    private void Show(LinkPreview? preview)
    {
        _answered = preview != null;
        var face = LinkChips.Face(_raw, _url, preview);
        _title.Text = face.Title;
        _hostWhole = face.Host;
        FitHost();
        // A title that already starts with the host shows alone, centred in the card (its height stays fixed).
        _host.Visibility = face.HostShown ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(this, face.AccessibleName);
        if (preview?.Icon is { } bytes)
        {
            var bitmap = new BitmapImage { DecodePixelWidth = 36, DecodePixelType = DecodePixelType.Logical };
            var image = new Image { Source = bitmap, Width = IconSize, Height = IconSize, Stretch = Stretch.Uniform };
            AutomationProperties.SetAutomationId(image, "chat.link-chip.icon");
            _iconBox.Child = image;
            _ = SetSource(bitmap, bytes);
        }
        else
        {
            var globe = new FontIcon
            {
                Glyph = "\uE774", FontSize = 15,   // Globe
                Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
            };
            AutomationProperties.SetAutomationId(globe, "chat.link-chip.globe");
            _iconBox.Child = globe;
        }
    }

    private async Task SetSource(BitmapImage bitmap, byte[] bytes)
    {
        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        await stream.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(bytes));
        stream.Seek(0);
        try { await bitmap.SetSourceAsync(stream); }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or ArgumentException)
        {
            // Bytes the system can't draw: the globe.
            _iconBox.Child = new FontIcon { Glyph = "\uE774", FontSize = 15, Foreground = Res<Brush>("TextFillColorSecondaryBrush") };
        }
    }

    private static T Res<T>(string key) => ThemeBrushes.Res<T>(key);
}

/// The chat's links (Controls/MarkdownRenderer's Hyperlink rule, LinkTargets §7.1): a web page opens in the browser; a
/// page on the gateway computer itself (loopback) or anything else refused does nothing here.
public static class ChatLinks
{
    public static void Open(Uri url)
    {
        if (url.Scheme is not ("http" or "https" or "mailto")) return;
        if (LinkTargets.Target(url).Kind is LinkTargetKind.Loopback or LinkTargetKind.Refused) return;
        _ = Windows.System.Launcher.LaunchUriAsync(url);
    }
}

/// A reply's words with its link chips (LinkChips.Split): each Markdown piece drawn as before, a chip in place of each
/// lone address. `settled`: a bot's reply that has finished arriving (LinkChips.Shows).
public static class ReplyWords
{
    private static ChatVisualTokens.TypeRamp Type => ChatVisualTokens.Type(HermesHQ.Features.Settings.ThemeService.State.DesktopLook);
    private static TextBlock Clock(string time) => new()
    {
        Text = time, FontSize = Type.Caption2.Size, HorizontalAlignment = HorizontalAlignment.Right,
        Foreground = ThemeBrushes.Get("HQLabel2Brush"),
    };
    /// [page-cards] `page`: the reply's chat and message, when its lone pages draw as page cards (a bot's reply, settled
    /// or still arriving: the card is the same size either way, "Building page…" until it settles).
    public static void Render(string markdown, Panel into, string? trailing, bool settled,
        (HermesHQ.ViewModels.ChatViewModel? Owner, string MessageId)? page = null)
    {
        if (page is { } chat && PageCards.Split(markdown) is var pieces && pieces.Any(p => p is PageSegment))
        {
            for (var i = 0; i < pieces.Count; i++)
            {
                var last = i == pieces.Count - 1;
                if (pieces[i] is PageSegment card)
                {
                    into.Children.Add(new PageCardView(card, chat.Owner, chat.MessageId, building: !settled));
                    if (last && trailing != null)
                        into.Children.Add(Clock(trailing));
                }
                else if (pieces[i] is WordsSegment words) Render(words.Markdown, into, last ? trailing : null, settled);
            }
            return;
        }
        var segments = LinkChips.Split(markdown, settled);
        for (var i = 0; i < segments.Count; i++)
        {
            var last = i == segments.Count - 1;
            switch (segments[i])
            {
                case WordsSegment words:
                    MarkdownRenderer.Render(words.Markdown, into, foreground: ThemeBrushes.Get("HQLabelBrush"),
                        trailing: last ? trailing : null, chatType: Type);
                    break;
                case ChipSegment chip:
                    into.Children.Add(new LinkChipView(chip));
                    if (last && trailing != null)
                        into.Children.Add(Clock(trailing));
                    break;
            }
        }
    }
}
