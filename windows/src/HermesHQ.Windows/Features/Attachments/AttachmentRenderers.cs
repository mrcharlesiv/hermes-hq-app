using Hermes.Core.Attachments;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace HermesHQ.Features.Attachments;

/// Attachments in bubbles (App/Chat/Attachments: AttachmentBubbleLayout, MediaTileView, FileRowView, MarkdownMedia,
/// ChatMediaRows; spec 1x-attachments §7.3–§7.7): a message's photos as one picture or a grid of square tiles ("+N" on
/// the fourth past four), loaded lazily with a placeholder, "Couldn’t load photo / Click to try again", "Photo too large
/// to load / Click to open", and your sending photos' upload rings; files, folders and links as rows ("PDF · 2.4 MB",
/// "Downloading… 40 %"); an image_generate result as its picture ("Rendering image" while it runs). A click opens the
/// viewer or the file; a right-click has Save As…, Share… and Copy Image (Open, Share…, Copy Path on a file).
internal static class AttachmentRenderers
{
    private static T Res<T>(string key) => ThemeBrushes.Res<T>(key);

    public static UIElement Attachment(ChatPart part, ChatMessage message)
    {
        var a = ((AttachmentPart)part).Attachment;
        var mine = message.Role == Role.User;
        if (a.IsImage)
        {
            var photos = message.Attachments.Where(x => x.IsImage).ToList();
            // The first photo part draws the message's whole set; the others have drawn with it.
            if (!ReferenceEquals(message.Parts.OfType<AttachmentPart>().First(p => p.Attachment.IsImage), part))
                return new Border { Visibility = Visibility.Collapsed };
            return Photos(photos, mine, message.Id);
        }
        return new FileRow(a, mine).Root;
    }

    // ------------------------------------------------------------------ photos

    private static FrameworkElement Photos(IReadOnlyList<MessageAttachment> photos, bool mine, string messageId)
    {
        var viewer = photos.Select(p => new ViewerItem(p.Name, () => Original(p))).ToList();
        if (photos.Count == 1)
        {
            var (w, h) = MediaLayout.Single(mine ? 320 : 280, photos[0].PixelWidth, photos[0].PixelHeight);
            var tile = new PhotoTile(photos[0], w, h, mine, viewer, 0, more: 0);
            tile.Root.Margin = new Thickness(0, 0, 0, 6);
            tile.Root.HorizontalAlignment = mine ? HorizontalAlignment.Right : HorizontalAlignment.Left;
            return tile.Root;
        }
        var width = mine ? 320 : 400;
        var (tiles, more) = MediaLayout.Grid(width, photos.Count);
        var canvas = new Canvas
        {
            Width = tiles.Max(t => t.X + t.Width), Height = tiles.Max(t => t.Y + t.Height), Margin = new Thickness(0, 0, 0, 6),
            HorizontalAlignment = mine ? HorizontalAlignment.Right : HorizontalAlignment.Left,
        };
        AutomationProperties.SetName(canvas, $"{photos.Count} photos");
        for (var i = 0; i < tiles.Count; i++)
        {
            var f = tiles[i];
            var tile = new PhotoTile(photos[i], f.Width, f.Height, mine, viewer, i, i == tiles.Count - 1 ? more : 0);
            Canvas.SetLeft(tile.Root, f.X);
            Canvas.SetTop(tile.Root, f.Y);
            canvas.Children.Add(tile.Root);
        }
        return canvas;
    }

    /// A picture's original on this PC, through the open chat's media store.
    private static Task<string> Original(MessageAttachment a) =>
        MediaContext.Current is { } m ? m.Center.Media.ImageAsync(a, m.Profile, m.SessionId)
            : Task.FromException<string>(new MediaLoadException(MediaLoadException.Kinds.Unavailable));

    private static MenuFlyout ImageMenu(Func<Task<string>> original, string name, XamlRoot? root)
    {
        async Task Run(string failure, Func<string, Task> act)
        {
            try { await act(await original()); }
            catch (MediaLoadException e) { await MediaActions.FailureAsync(root, failure, e.FileMessage, () => Run(failure, act)); }
            catch (Exception e) { AppLog.Error("attachments", e); await MediaActions.FailureAsync(root, failure, e.Message, () => Run(failure, act)); }
        }
        var menu = new MenuFlyout();
        void Add(string text, string glyph, string failure, Func<string, Task> act)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            item.Click += (_, _) => _ = Run(failure, act);
            menu.Items.Add(item);
        }
        Add("Save As…", "", "Couldn’t Save", p => MediaActions.SaveAsAsync(p, name));
        Add("Share…", "", "Couldn’t Share", p => MediaActions.ShareAsync(p, name));
        Add("Copy Image", "", "Couldn’t Copy", p => MediaActions.CopyImageAsync(p, name));
        return menu;
    }

    private sealed class PhotoTile
    {
        public readonly Grid Root;
        private readonly MessageAttachment _a;
        private readonly double _w, _h;
        private readonly bool _mine;
        private readonly Image _image = new() { Stretch = Stretch.UniformToFill, VerticalAlignment = VerticalAlignment.Top };
        private readonly Grid _overlay = new();
        private readonly IReadOnlyList<ViewerItem> _viewer;
        private readonly int _index;
        private bool _failed, _tooLarge, _watching;

        public PhotoTile(MessageAttachment a, double w, double h, bool mine, IReadOnlyList<ViewerItem> viewer, int index, int more)
        {
            _a = a; _w = w; _h = h; _mine = mine; _viewer = viewer; _index = index;
            Root = new Grid { Width = w, Height = h, CornerRadius = new CornerRadius(12), Background = Res<Brush>("SubtleFillColorTertiaryBrush") };
            Root.Children.Add(_image);
            Root.Children.Add(_overlay);
            if (more > 0)
            {
                var dim = new Grid { Background = new SolidColorBrush(Windows.UI.Color.FromArgb(115, 0, 0, 0)) };
                dim.Children.Add(new TextBlock
                {
                    Text = $"+{more}", FontSize = 24, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(Colors.White),
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                });
                Root.Children.Add(dim);
            }
            Root.BorderBrush = Res<Brush>("CardStrokeColorDefaultBrush");
            Root.BorderThickness = new Thickness(0.5);
            AutomationProperties.SetName(Root, a.Name == "Photo" ? "Photo" : $"Photo, {a.Name}");
            AutomationProperties.SetHelpText(Root, more > 0 ? $"Opens this photo and {more} more" : "Opens the photo");
            Root.IsTabStop = true;
            Root.Tapped += (_, e) => { e.Handled = true; Activate(); };
            Root.KeyDown += (_, e) => { if (e.Key is VirtualKey.Enter or VirtualKey.Space) { e.Handled = true; Activate(); } };
            Root.Loaded += (_, _) =>
            {
                Root.ContextFlyout = ImageMenu(() => Original(a), a.Name, Root.XamlRoot);
                WatchUpload();
            };
            _ = LoadAsync();
        }

        private void Activate()
        {
            if (_tooLarge) { _ = FileRow.OpenGatewayFileAsync(_a, Root.XamlRoot, null); return; }
            if (_failed) { _ = LoadAsync(); return; }
            MediaViewerWindow.Show(_viewer, _index);
        }

        private void ClearOverlay()
        {
            foreach (var child in _overlay.Children)
                if (child is ProgressRing ring) ring.IsActive = false;
            _overlay.Children.Clear();
        }

        private async Task LoadAsync()
        {
            _failed = false;
            ClearOverlay();
            var load = Original(_a);
            var slow = Task.Delay(600);
            if (await Task.WhenAny(load, slow) == slow && !load.IsCompleted)
                _overlay.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            try
            {
                var path = await load;
                _image.Source = await MediaActions.BitmapAsync(path, (int)Math.Ceiling(_w * 2));
                ClearOverlay();
            }
            catch (MediaLoadException e) when (e.Kind == MediaLoadException.Kinds.TooLarge)
            {
                _tooLarge = true;
                Failure("Photo too large to load", "Click to open");
                AutomationProperties.SetName(Root, "Photo too large to load. Click to open.");
            }
            catch (Exception e)
            {
                if (e is not MediaLoadException) AppLog.Error("attachments", e);
                _failed = true;
                Failure("Couldn’t load photo", "Click to try again");
                AutomationProperties.SetName(Root, $"Couldn’t load {_a.Name}. Click to try again.");
            }
        }

        /// The failure tile: a dashed edge, ↻, the words, the file's name (only the glyph below 120 px).
        private void Failure(string title, string action)
        {
            ClearOverlay();
            _overlay.Children.Add(new Microsoft.UI.Xaml.Shapes.Rectangle
            {
                Stroke = Res<Brush>("CardStrokeColorDefaultBrush"), StrokeThickness = 1, StrokeDashArray = [4, 3], RadiusX = 12, RadiusY = 12,
            });
            var words = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Spacing = 4 };
            words.Children.Add(new FontIcon { Glyph = "", FontSize = 22 });
            if (_h >= 120)
            {
                words.Children.Add(new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.Medium, HorizontalAlignment = HorizontalAlignment.Center });
                words.Children.Add(new TextBlock { Text = action, FontSize = 13, Foreground = Res<Brush>("AccentTextFillColorPrimaryBrush"), HorizontalAlignment = HorizontalAlignment.Center });
                words.Children.Add(new TextBlock
                {
                    Text = _a.Name, FontSize = 12, Foreground = Res<Brush>("TextFillColorTertiaryBrush"), MaxWidth = _w - 16,
                    TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Center,
                });
            }
            _overlay.Children.Add(words);
        }

        /// Your sending photo's upload ring, from the account's center (never a rebuild of the bubble).
        private void WatchUpload()
        {
            if (_watching || _a.Source is not AttachmentSource.Local local || MediaContext.Current is not { } m || !_mine) return;
            _watching = true;
            var ring = new ProgressRing { IsIndeterminate = false, Maximum = 100, Width = 24, Height = 24, Foreground = new SolidColorBrush(Colors.White) };
            var scrim = new Grid { Background = new SolidColorBrush(Windows.UI.Color.FromArgb(77, 0, 0, 0)), Visibility = Visibility.Collapsed };
            scrim.Children.Add(ring);
            Root.Children.Add(scrim);
            void Show()
            {
                if (m.Center.Item(local.DraftId)?.Upload is UploadState.Uploading u)
                {
                    ring.Value = u.Total > 0 ? 100.0 * u.Sent / u.Total : 0;
                    ring.IsActive = true;
                    scrim.Visibility = Visibility.Visible;
                    AutomationProperties.SetItemStatus(Root, $"Uploading, {(int)ring.Value} percent");
                }
                else
                {
                    ring.IsActive = false;
                    scrim.Visibility = Visibility.Collapsed;
                    AutomationProperties.SetItemStatus(Root, "");
                }
            }
            void OnItem(string id) { if (id == local.DraftId && !AppShutdown.Stopping) Root.DispatcherQueue.TryEnqueue(() => { if (!AppShutdown.Stopping) Show(); }); }
            m.Center.ItemChanged += OnItem;
            Root.Unloaded += (_, _) =>
            {
                m.Center.ItemChanged -= OnItem;
                _watching = false;
                ring.IsActive = false;
                Root.Children.Remove(scrim);
            };
            Show();
        }
    }

    // ------------------------------------------------------------------ files

    internal sealed class FileRow
    {
        public readonly Grid Root = new() { ColumnSpacing = 10, Padding = new Thickness(12, 12, 12, 12), Margin = new Thickness(0, 0, 0, 4), CornerRadius = new CornerRadius(10) };
        private readonly MessageAttachment _a;
        private readonly TextBlock _detail;
        private CancellationTokenSource? _download;

        public FileRow(MessageAttachment a, bool mine)
        {
            _a = a;
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Root.Background = mine ? new SolidColorBrush(Windows.UI.Color.FromArgb(30, 255, 255, 255)) : Res<Brush>("SubtleFillColorSecondaryBrush");
            var accent = Res<Brush>("AccentFillColorDefaultBrush");
            var circle = new Border
            {
                Width = 40, Height = 40, CornerRadius = new CornerRadius(20), VerticalAlignment = VerticalAlignment.Center,
                Background = mine ? new SolidColorBrush(Windows.UI.Color.FromArgb(56, 255, 255, 255)) : new SolidColorBrush(Accent(0.15)),
                Child = new FontIcon
                {
                    Glyph = a.Kind == AttachmentKind.Link ? "" : MediaKinds.Glyph(a.MediaKind), FontSize = 17,
                    Foreground = mine ? new SolidColorBrush(Colors.White) : accent,
                },
            };
            Root.Children.Add(circle);
            var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var fg = mine ? Res<Brush>("TextOnAccentFillColorPrimaryBrush") : null;
            words.Children.Add(new TextBlock
            {
                Text = a.Name, FontSize = 14, FontWeight = FontWeights.SemiBold, MaxLines = 2, TextWrapping = TextWrapping.Wrap,
                TextTrimming = TextTrimming.CharacterEllipsis, Foreground = fg ?? Res<Brush>("TextFillColorPrimaryBrush"),
            });
            _detail = new TextBlock
            {
                Text = Detail(), FontSize = 12,
                Foreground = mine ? Res<Brush>("TextOnAccentFillColorSecondaryBrush") : Res<Brush>("TextFillColorSecondaryBrush"),
            };
            words.Children.Add(_detail);
            Grid.SetColumn(words, 1);
            Root.Children.Add(words);

            var kind = a.Kind switch { AttachmentKind.Link => "Link", AttachmentKind.Folder => "Folder", _ => "File" };
            AutomationProperties.SetName(Root, a.Kind == AttachmentKind.Link ? $"Link, {a.GatewayPath ?? a.Name}" : $"{kind}, {a.Name}, {Detail()}");
            if (a.Kind != AttachmentKind.Folder)
            {
                AutomationProperties.SetHelpText(Root, a.Kind == AttachmentKind.Link ? "Opens the page" : "Opens the file");
                Root.IsTabStop = true;
                Root.Tapped += (s, e) => { e.Handled = true; _ = ActivateAsync(); };
                Root.KeyDown += (s, e) => { if (e.Key is VirtualKey.Enter or VirtualKey.Space) { e.Handled = true; _ = ActivateAsync(); } };
            }
            Root.ContextFlyout = Menu();
        }

        private static Windows.UI.Color Accent(double alpha)
        {
            var c = Application.Current.Resources.TryGetValue("SystemAccentColor", out var v) && v is Windows.UI.Color color ? color
                : Windows.UI.Color.FromArgb(255, 0, 120, 212);
            return Windows.UI.Color.FromArgb((byte)(alpha * 255), c.R, c.G, c.B);
        }

        private string Detail() => _a.Kind == AttachmentKind.Link ? "Link" : _a.Detail;

        private MenuFlyout Menu()
        {
            var menu = new MenuFlyout();
            if (_a.Kind is AttachmentKind.File or AttachmentKind.Image)
            {
                var open = new MenuFlyoutItem { Text = "Open", Icon = new FontIcon { Glyph = "" } };
                open.Click += (_, _) => _ = ActivateAsync();
                menu.Items.Add(open);
                var share = new MenuFlyoutItem { Text = "Share…", Icon = new FontIcon { Glyph = "" } };
                share.Click += (_, _) => _ = ShareAsync();
                menu.Items.Add(share);
            }
            var copy = new MenuFlyoutItem { Text = _a.Kind == AttachmentKind.Link ? "Copy Link" : "Copy Path", Icon = new FontIcon { Glyph = "" } };
            copy.Click += (_, _) => MediaActions.CopyText(_a.GatewayPath ?? _a.Name);
            menu.Items.Add(copy);
            return menu;
        }

        private async Task ShareAsync()
        {
            try
            {
                var path = _a.Source is AttachmentSource.Local l && File.Exists(l.LocalPath) ? l.LocalPath : await DownloadAsync();
                if (path != null) await MediaActions.ShareAsync(path, _a.Name);
            }
            catch (Exception e) { AppLog.Error("attachments", e); }
        }

        private async Task ActivateAsync()
        {
            if (_a.Kind == AttachmentKind.Link)
            {
                var target = _a.GatewayPath ?? _a.Name;
                if (Uri.TryCreate(target.Contains("://") ? target : "https://" + target, UriKind.Absolute, out var url)) await Launcher.LaunchUriAsync(url);
                return;
            }
            // A second click while it downloads cancels: "Cancelled" for 1.5 s, then the usual detail.
            if (_download != null)
            {
                _download.Cancel();
                return;
            }
            if (_a.Source is AttachmentSource.Local l && File.Exists(l.LocalPath)) { await MediaActions.OpenAsync(l.LocalPath, _a.Name); return; }
            if (await DownloadAsync(opening: true) is { } path) await MediaActions.OpenAsync(PageEncoding.DrawableFile(path), _a.Name);
        }

        private async Task<string?> DownloadAsync(bool opening = false)
        {
            _download = new CancellationTokenSource();
            var ui = Root.DispatcherQueue;
            try
            {
                return await OpenGatewayFileAsync(_a, Root.XamlRoot, (got, total) => ui.TryEnqueue(() =>
                {
                    if (total > 0) _detail.Text = $"Downloading… {(int)(100.0 * got / total)} %";
                }), _download.Token, openIt: false, opening: opening);
            }
            catch (OperationCanceledException)
            {
                _detail.Text = "Cancelled";
                await Task.Delay(1500);
                return null;
            }
            finally
            {
                _download = null;
                _detail.Text = Detail();
            }
        }

        /// Downloads a gateway file (512 MB ceiling) and opens it; "Couldn't Open File" with the reason otherwise.
        /// [page-fresh-read] A page being opened (`opening`, true when `openIt`) is read again from the bot's computer
        /// (FilePreviewPresenter: `fresh: page`), the kept copy if that fails; anything else, or a page saved or shared,
        /// comes from the kept copy. [utf8-pages] A page that declares no charset opens as UTF-8 (PageEncoding).
        public static async Task<string?> OpenGatewayFileAsync(MessageAttachment a, XamlRoot? root, Action<long, long>? progress,
            CancellationToken ct = default, bool openIt = true, bool? opening = null)
        {
            if (MediaContext.Current is not { } m || a.GatewayPath is not { } path)
            {
                await MediaActions.AlertAsync(root, "Couldn't Open File", "Couldn’t reach your gateway. Try again.");
                return null;
            }
            try
            {
                var file = await m.Center.Media.GatewayFileAsync(path, a.Name, m.Profile, m.SessionId, progress, ct,
                    fresh: PageCards.ReadsFresh(a.Name, opening ?? openIt));
                if (openIt) await MediaActions.OpenAsync(PageEncoding.DrawableFile(file), a.Name);
                return file;
            }
            catch (MediaLoadException e)
            {
                await MediaActions.AlertAsync(root, "Couldn't Open File", e.FileMessage);
                return null;
            }
        }
    }

    // ------------------------------------------------------------------ image_generate

    public static UIElement Generated(ChatPart part, ChatMessage message)
    {
        var g = (GeneratedImagePart)part;
        var info = g.Image;
        var (w, h) = info.Frame(320);
        var root = new Grid
        {
            Width = w, Height = h, CornerRadius = new CornerRadius(18), Margin = new Thickness(0, 2, 0, 8),
            HorizontalAlignment = HorizontalAlignment.Left, Background = Res<Brush>("SubtleFillColorTertiaryBrush"),
        };
        if (info.Source is not { } source)
        {
            root.Children.Add(new FontIcon { Glyph = "", FontSize = 28, Foreground = Res<Brush>("TextFillColorTertiaryBrush") });
            AutomationProperties.SetName(root, "Rendering image");
            return root;
        }
        var attachment = Uri.TryCreate(source, UriKind.Absolute, out var url) && url.Scheme == "https"
            ? new MessageAttachment(AttachmentKind.Image, new AttachmentSource.Remote(url), info.Name)
            : new MessageAttachment(AttachmentKind.Image, new AttachmentSource.Gateway(source), info.Name, info.PixelWidth, info.PixelHeight);
        var image = new Image { Stretch = Stretch.UniformToFill, Opacity = 0 };
        root.Children.Add(image);
        AutomationProperties.SetName(root, $"Image, {info.Name}");
        root.IsTabStop = true;
        var viewer = new List<ViewerItem> { new(info.Name, () => Original(attachment)) };
        root.Tapped += (_, e) => { e.Handled = true; MediaViewerWindow.Show(viewer, 0); };
        root.Loaded += (_, _) => root.ContextFlyout = ImageMenu(() => Original(attachment), info.Name, root.XamlRoot);
        _ = LoadGeneratedAsync(root, image, attachment, info, w);
        return root;
    }

    private static async Task LoadGeneratedAsync(Grid root, Image image, MessageAttachment a, GeneratedImageInfo info, double w)
    {
        try
        {
            image.Source = await MediaActions.BitmapAsync(await Original(a), (int)Math.Ceiling(w * 2));
            image.Opacity = 1; // the Mac fades it in over 0.2 s
        }
        catch (Exception e)
        {
            if (e is not MediaLoadException) AppLog.Error("attachments", e);
            // A good result that won't load collapses to a link: "Open image: <name>".
            root.Children.Clear();
            root.Width = double.NaN;
            root.Height = double.NaN;
            root.Background = null;
            var link = new HyperlinkButton { Content = $"Open image: {info.Name}" };
            link.Click += async (_, _) =>
            {
                if (a.Source is AttachmentSource.Remote r) await Launcher.LaunchUriAsync(r.Url);
                else await FileRow.OpenGatewayFileAsync(a, root.XamlRoot, null);
            };
            root.Children.Add(link);
        }
    }
}
