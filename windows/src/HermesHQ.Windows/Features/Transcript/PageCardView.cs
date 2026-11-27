using Hermes.Core.Attachments;
using Hermes.Core.Insights;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;
using HermesHQ.Features.Attachments;
using HermesHQ.Services;
using HermesHQ.ViewModels;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace HermesHQ.Features.Transcript;

/// A page card (App/Chat/Cells/PageCardView.swift at 93f984bb1): an HTML page a bot hands over alone on its line
/// (`::preview{file="…"}`, `MEDIA:/…/page.html`) in a reply. The picture's place over the page's name, its size fixed
/// from the start (PageCards: 260 picture, at most 480 wide, 12 / 9 padding), so nothing moves when a picture lands.
/// A click opens the page live in its own window (MediaActions.OpenAsync → FileWindows); a right-click gives the page's
/// own menu (Open, Pin as Tile / Unpin, Share…, Save As…, Copy Path). [page-fold] Folded to its caption ("Updated
/// below") while a later reply of the chat hands the same page over again; [pins] a pin on the picture's corner while
/// the page is pinned. The picture (PagePictures: the page drawn off screen in WebView2 and photographed) fades in over
/// the page's shape (the Mac's skeleton) when it lands, its fixed height unchanged; "Building page…" until it does while
/// the reply still arrives. A page that can't be pictured leaves the page's colour, the shape gone (nothing is coming).
public sealed class PageCardView : Grid
{
    public const double NameLine = 21, HintLine = 15;   // the transcript's body and time lines (LinkChipView's)
    public static double CardHeight => PageCards.Height(NameLine, HintLine);
    public static double FoldedCardHeight => PageCards.FoldedHeight(NameLine, HintLine);

    private readonly PageSegment _page;
    private readonly ChatViewModel? _owner;
    private readonly string _messageId;
    private readonly bool _building;
    private readonly Border _picture, _pin, _rule;
    private readonly StackPanel _skeleton;
    private readonly Image _image;
    private PagePicture? _shown;
    private string? _wanted;
    private bool _themeHooked;
    private DateTime? _asked, _landed;
    private double? _heightBefore;
    private readonly TextBlock _name, _hint;
    private readonly FontIcon _open;
    private TilePinStore? _pins;
    private bool _folded;

    /// Folded now (the walk reads it).
    public bool Folded => _folded;
    public string PagePath => _page.Path;
    public bool PinShown => _pin.Visibility == Visibility.Visible;
    public string NameShown => _name.Text;
    public string HintShown => _hint.Text;
    /// [page-cards] The picture shown now (null while the page's shape stands in its place).
    public PagePixels? PictureShown => _shown?.Pixels;
    /// How long the shown picture took from being asked to landing.
    public TimeSpan? PictureTook => _landed - _asked;
    /// The card's height just before its picture landed.
    public double? HeightBeforePicture => _heightBefore;

    public PageCardView(PageSegment page, ChatViewModel? owner, string messageId, bool building)
    {
        _page = page;
        _owner = owner;
        _messageId = messageId;
        _building = building;
        HorizontalAlignment = HorizontalAlignment.Left;
        Margin = new Thickness(0, 6, 0, 4);
        CornerRadius = new CornerRadius(12);
        BorderThickness = new Thickness(1);
        BorderBrush = Res<Brush>("CardStrokeColorDefaultBrush");
        Background = Res<Brush>("SubtleFillColorSecondaryBrush");
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        AutomationProperties.SetAutomationId(this, PageCards.AutomationId);
        AutomationProperties.SetHelpText(this, PageCards.AccessibleHint);
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(PageCards.PictureHeight) });
        // The rule takes no room (row 1 stays 0): it is drawn over the caption's top edge at y = pictureHeight, as the
        // Mac's `rule.frame` is, so the caption keeps all of padV + name + 2 + hint + padV and the hint isn't cut.
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(0) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // The picture's place: the page's shape (a heading bar and lines) on the page's colour.
        var shape = new StackPanel { Margin = new Thickness(24, 22, 24, 0), Spacing = 10 };
        shape.Children.Add(Bar(0.55, 14));
        for (var i = 0; i < 5; i++) shape.Children.Add(Bar(i == 4 ? 0.4 : 0.9, 8));
        _skeleton = shape;
        // The page's chart (or its top) fitted whole into the card, 8 in from its edges, centred on the page's colour.
        _image = new Image { Stretch = Stretch.Uniform, Margin = new Thickness(8), Opacity = 0, Visibility = Visibility.Collapsed,
            OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(200) } };
        var room = new Grid();
        room.Children.Add(shape);
        room.Children.Add(_image);
        _picture = new Border { Background = Res<Brush>("SolidBackgroundFillColorTertiaryBrush"), Child = room };
        AutomationProperties.SetAccessibilityView(_picture, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        Children.Add(_picture);
        _pin = new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Margin = new Thickness(0, 8, 8, 0),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Background = Res<Brush>("SystemFillColorCautionBrush"), Visibility = Visibility.Collapsed,
            Child = new FontIcon { Glyph = "\uE718", FontSize = 11, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) },
        };
        AutomationProperties.SetAutomationId(_pin, "chat.page-card.pin");
        Children.Add(_pin);
        _rule = new Border { Background = Res<Brush>("DividerStrokeColorDefaultBrush"), Height = 1, VerticalAlignment = VerticalAlignment.Top };
        SetRow(_rule, 2);
        Canvas.SetZIndex(_rule, 1);   // over the caption, which is added after it
        Children.Add(_rule);

        var caption = new Grid { Padding = new Thickness(PageCards.PadH, PageCards.PadV, PageCards.PadH, PageCards.PadV), ColumnSpacing = 8 };
        caption.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        caption.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        caption.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
        var glyph = new FontIcon { Glyph = "\uE8A5", FontSize = 15, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0),
            Foreground = Res<Brush>("TextFillColorSecondaryBrush") };
        caption.Children.Add(glyph);
        var words = new StackPanel();
        _name = new TextBlock { FontSize = 14, LineHeight = NameLine, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap, Foreground = Res<Brush>("TextFillColorPrimaryBrush") };
        _hint = new TextBlock { FontSize = 11, LineHeight = HintLine, Margin = new Thickness(0, 2, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap, Foreground = Res<Brush>("TextFillColorSecondaryBrush") };
        AutomationProperties.SetAccessibilityView(_name, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_hint, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        words.Children.Add(_name);
        words.Children.Add(_hint);
        SetColumn(words, 1);
        caption.Children.Add(words);
        _open = new FontIcon { FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Foreground = Res<Brush>("TextFillColorTertiaryBrush") };
        SetColumn(_open, 2);
        caption.Children.Add(_open);
        SetRow(caption, 2);
        Children.Add(caption);

        PointerEntered += (_, _) => Background = Res<Brush>("SubtleFillColorTertiaryBrush");
        PointerExited += (_, _) => Background = Res<Brush>("SubtleFillColorSecondaryBrush");
        Tapped += (_, e) => { e.Handled = true; _ = OpenAsync(); };
        KeyDown += (_, e) => { if (e.Key is VirtualKey.Enter or VirtualKey.Space) { e.Handled = true; _ = OpenAsync(); } };
        var menu = new MenuFlyout();
        menu.Opening += (_, _) => FillMenu(menu);
        ContextFlyout = menu;

        SetFolded(FoldedNow(), force: true);
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private static Border Bar(double fraction, double height) => new()
    {
        Height = height, CornerRadius = new CornerRadius(height / 2), HorizontalAlignment = HorizontalAlignment.Left,
        Width = 400 * fraction, Background = Res<Brush>("ControlFillColorSecondaryBrush"),
    };

    /// `width(maxText:)`: the reply column's room up to 480; the height fixed by the fold alone.
    protected override Windows.Foundation.Size MeasureOverride(Windows.Foundation.Size available)
    {
        var size = new Windows.Foundation.Size(PageCards.Width(available.Width), _folded ? FoldedCardHeight : CardHeight);
        base.MeasureOverride(size);
        return size;
    }

    protected override Windows.Foundation.Size ArrangeOverride(Windows.Foundation.Size final)
    {
        var size = new Windows.Foundation.Size(PageCards.Width(final.Width), _folded ? FoldedCardHeight : CardHeight);
        base.ArrangeOverride(size);
        return size;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_owner != null) { _owner.ItemsChanged -= OnItems; _owner.ItemsChanged += OnItems; }
        if (AppState.Client is { } client)
        {
            _pins = HermesHQ.Features.Insights.TilesPage.PinsFor(client);
            _pins.Changed -= OnPins;
            _pins.Changed += OnPins;
        }
        PagePictures.Shared.TurnEnded -= OnTurnEnded;
        PagePictures.Shared.TurnEnded += OnTurnEnded;
        PagePictures.Shared.HeadLearnt -= OnHeadLearnt;
        PagePictures.Shared.HeadLearnt += OnHeadLearnt;
        if (!_themeHooked) { _themeHooked = true; ActualThemeChanged += (_, _) => { if (IsLoaded) LoadPicture(); }; }
        if (_owner != null) PagePictures.Watch(_owner.Session);
        SetFolded(FoldedNow());
        ShowPinned();
        if (!_folded) LoadPicture();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_owner != null) _owner.ItemsChanged -= OnItems;
        if (_pins != null) _pins.Changed -= OnPins;
        PagePictures.Shared.TurnEnded -= OnTurnEnded;
        PagePictures.Shared.HeadLearnt -= OnHeadLearnt;
    }

    private PageContext? Context => PagePictures.Context(_owner?.Session);
    private bool Dark => ActualTheme == ElementTheme.Dark;

    /// A turn of this card's chat ended: the page may have been rewritten, so it is pictured again.
    private void OnTurnEnded(PageContext context)
    {
        if (context == Context && !_folded) LoadPicture();
    }

    /// The read that drew a picture found the page's title: the caption names it.
    private void OnHeadLearnt() => DispatcherQueue.TryEnqueue(ShowFace);

    /// `loadPicture`: a kept picture at once; otherwise the page's shape until the picture comes (the last picture staying
    /// up while a new one draws), nothing while the reply that hands the page over is still arriving.
    private void LoadPicture()
    {
        if (Context is not { } context) { ShowPicture(null); return; }
        var snapshots = PagePictures.Shared;
        var cached = snapshots.Cached(_page.Path, context, Dark);
        switch (PageCardPictures.Begin(_building, _shown != null, cached != null))
        {
            case PageCardPictureStep.Wait: ShowPicture(null); return;
            case PageCardPictureStep.ShowCached: _asked = DateTime.UtcNow; ShowPicture(cached); return;
        }
        if (_shown == null) ShowPicture(null);
        var wanted = snapshots.Key(_page.Path, context, Dark);
        _wanted = wanted;
        _asked = DateTime.UtcNow;
        snapshots.Picture(_page.Path, _page.Name, context, Dark, PageShape.Phone, image => DispatcherQueue.TryEnqueue(() =>
        {
            var still = _wanted == wanted && Context is { } now && snapshots.Key(_page.Path, now, Dark) == wanted;
            switch (PageCardPictures.Arrived(still, image != null, _shown != null))
            {
                case PageCardArrival.Show: ShowPicture(image); break;
                case PageCardArrival.Failed: ShowPicture(null, failed: true); break;
            }
            ShowFace();
        }));
    }

    /// `show`: the picture over the page's colour (its top-left pixel), the shape gone; `failed`: the shape stops (nothing
    /// is coming). The card's height never changes (MeasureOverride).
    private void ShowPicture(PagePicture? picture, bool failed = false)
    {
        if (picture != null && !ReferenceEquals(picture, _shown))
        {
            _heightBefore = ActualHeight;
            var px = picture.Pixels;
            var bitmap = new Microsoft.UI.Xaml.Media.Imaging.WriteableBitmap(px.Width, px.Height);
            using (var s = System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsStream(bitmap.PixelBuffer))
                s.Write(px.Bgra, 0, Math.Min(px.Bgra.Length, px.Width * px.Height * 4));
            bitmap.Invalidate();
            _image.Source = bitmap;
            _image.Visibility = Visibility.Visible;
            if (!AnimationsEnabled()) _image.OpacityTransition = null;   // reduced motion: no fade
            _image.Opacity = 1;
            _landed = DateTime.UtcNow;
            _picture.Background = px.CornerColor() is { } c
                ? new SolidColorBrush(Windows.UI.Color.FromArgb(255, c.R, c.G, c.B))
                : Res<Brush>("SolidBackgroundFillColorTertiaryBrush");
        }
        _shown = picture ?? _shown;
        _skeleton.Visibility = _shown != null || failed ? Visibility.Collapsed : Visibility.Visible;
        ShowFace();
    }

    private void OnItems() => DispatcherQueue.TryEnqueue(() => SetFolded(FoldedNow()));
    private void OnPins() => DispatcherQueue.TryEnqueue(ShowPinned);

    /// [page-fold] A later reply of this chat hands the same page over again.
    private bool FoldedNow()
    {
        if (_owner == null) return false;
        var latest = PageCards.Latest(_owner.Session.Messages);
        return latest.TryGetValue(_page.Path, out var newest) && newest != _messageId;
    }

    private void SetFolded(bool folded, bool force = false)
    {
        if (!force && folded == _folded) return;
        _folded = folded;
        RowDefinitions[0].Height = new GridLength(folded ? 0 : PageCards.PictureHeight);
        _picture.Visibility = _rule.Visibility = folded ? Visibility.Collapsed : Visibility.Visible;
        _open.Glyph = folded ? "\uE74B" : "\uE740";   // Down; Full Screen (the Mac's arrow.down / arrow.up.left.and.arrow.down.right)
        ShowFace();
        ShowPinned();
        InvalidateMeasure();
        if (!folded && !force && IsLoaded) LoadPicture();
    }

    /// The page's own title over its file once a read found one; "Building page…" until the picture lands.
    private void ShowFace()
    {
        var title = Context is { } c ? PagePictures.Shared.Head(_page.Path, c)?.Title : null;
        var face = PageCards.Face(_page.Name, title, _folded, _building, pictured: _shown != null);
        _name.Text = face.Name;
        _hint.Text = face.Hint;
        AutomationProperties.SetName(this, face.AccessibleName);
    }

    private (string Profile, string SessionId, string Title)? Chat() =>
        _owner is { } o ? (o.Session.Profile, o.Session.MediaSessionId, o.Session.Title) : null;

    private bool Pinned => _pins != null && Chat() is { } c && _pins.IsPinned(c.Profile, _page.Path);

    private void ShowPinned()
    {
        var pinned = Pinned;
        _pin.Visibility = pinned && !_folded ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetItemStatus(this, pinned ? "Pinned" : "");
    }

    private void FillMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        var canPin = _pins != null && Chat() != null;
        foreach (var row in PageCards.Menu(canPin, Pinned))
        {
            var glyph = row.Id switch
            {
                "page.open" => "\uE8A7", "page.pin" => Pinned ? "\uE77A" : "\uE718", "page.share" => "\uE72D", "page.save" => "\uE74E", _ => "\uE8C8",
            };
            var item = new MenuFlyoutItem { Text = row.Title, Icon = new FontIcon { Glyph = glyph } };
            AutomationProperties.SetAutomationId(item, row.Id);
            var id = row.Id;
            item.Click += (_, _) => Act(id);
            menu.Items.Add(item);
        }
    }

    private void Act(string id)
    {
        switch (id)
        {
            case "page.open": _ = OpenAsync(); break;
            case "page.pin": TogglePin(); break;
            case "page.share": _ = WithFileAsync(p => MediaActions.ShareAsync(p, _page.Name)); break;
            case "page.save": _ = WithFileAsync(p => MediaActions.SaveAsAsync(p, _page.Name)); break;
            case "page.copy-path": MediaActions.CopyText(_page.Path); break;
        }
    }

    private void TogglePin()
    {
        if (_pins == null || Chat() is not { } c) return;
        if (_pins.IsPinned(c.Profile, _page.Path)) _pins.Unpin(TilePin.Key(c.Profile, _page.Path));
        else _pins.Pin(TilePin.Make(TileKind.File, _page.Path, _page.Name, c.Profile, c.SessionId, c.Title));
        ShowPinned();
    }

    private MessageAttachment? File() => AttachmentHydration.ReplyAttachment(_page.Path);

    /// Click: the page, downloaded from the bot's computer, live in a window of its own (FileWindows).
    public async Task OpenAsync()
    {
        if (File() is not { } a) return;
        try { await AttachmentRenderers.FileRow.OpenGatewayFileAsync(a, XamlRoot, null); }
        catch (Exception e) { AppLog.Error("page-cards", e); }
    }

    private async Task WithFileAsync(Func<string, Task> act)
    {
        if (File() is not { } a) return;
        try
        {
            if (await AttachmentRenderers.FileRow.OpenGatewayFileAsync(a, XamlRoot, null, openIt: false) is { } path) await act(path);
        }
        catch (Exception e) { AppLog.Error("page-cards", e); }
    }

    private static bool AnimationsEnabled()
    {
        try { return new Windows.UI.ViewManagement.UISettings().AnimationsEnabled; }
        catch (Exception) { return true; }
    }

    private static T Res<T>(string key) => ThemeBrushes.Res<T>(key);
}
