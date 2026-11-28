using Hermes.Core.Attachments;
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

/// One picture in the viewer: its name and a way to get its original on this PC (cached, inline, or downloaded).
internal sealed record ViewerItem(string Name, Func<Task<string>> Original);

/// The photo viewer (App/Chat/Viewer/MediaViewerController.swift; spec 1x-attachments §9), in its own window over the
/// app's: black, the tapped message's photos paged left and right ("2 of 3"), zoom to 5× (Ctrl+wheel or pinch), a
/// double-click toggles 2.5×, Done at the top right, Share at the bottom left and Save at the bottom right ("Saved" for
/// 1.8 s). Esc closes.
internal sealed partial class MediaViewerWindow : Window
{
    private readonly IReadOnlyList<ViewerItem> _items;
    private readonly FlipView _pages = new() { Background = new SolidColorBrush(Colors.Black) };
    private readonly TextBlock _title = new()
    {
        Foreground = new SolidColorBrush(Colors.White), FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly Button _save, _share, _markup, _done;
    private readonly Dictionary<int, string> _originals = [];

    private static Button BarButton(string glyph, string text, string id)
    {
        var b = new Button
        {
            Content = Label(glyph, text), Foreground = new SolidColorBrush(Colors.White), CornerRadius = new CornerRadius(14),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(46, 255, 255, 255)), BorderThickness = new Thickness(0),
            Padding = new Thickness(12, 6, 14, 6),
        };
        AutomationProperties.SetName(b, text);
        AutomationProperties.SetAutomationId(b, id);
        return b;
    }

    private static StackPanel Label(string glyph, string text)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (glyph.Length > 0) p.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14 });
        p.Children.Add(new TextBlock { Text = text });
        return p;
    }

    private MediaViewerWindow(IReadOnlyList<ViewerItem> items, int start)
    {
        _items = items;
        Title = items.Count > 1 ? "Photos" : items[0].Name;
        ExtendsContentIntoTitleBar = true;
        if (App.Window is { } main)
        {
            var size = main.AppWindow.Size;
            AppWindow.Resize(new Windows.Graphics.SizeInt32(Math.Max(640, size.Width - 80), Math.Max(480, size.Height - 80)));
            AppWindow.Move(new Windows.Graphics.PointInt32(main.AppWindow.Position.X + 40, main.AppWindow.Position.Y + 40));
        }
        _done = BarButton("", "Done", "viewer.close");
        _share = BarButton("", "Share", "viewer.share");
        _markup = BarButton("\uEE56", "Mark Up", "viewer.markup");
        _save = BarButton("", "Save", "viewer.save");
        _done.Click += (_, _) => Close();
        _share.Click += async (_, _) => await ShareAsync();
        _markup.Click += async (_, _) => await MarkupAsync();
        _save.Click += async (_, _) => await SaveAsync();

        var top = new Grid { Height = 48, Padding = new Thickness(12, 6, 12, 6), Background = new SolidColorBrush(Colors.Black) };
        top.Children.Add(_title);
        _done.HorizontalAlignment = HorizontalAlignment.Right;
        top.Children.Add(_done);
        var drag = new Grid { Background = new SolidColorBrush(Colors.Transparent), Margin = new Thickness(0, 0, 120, 0) };
        top.Children.Insert(0, drag);
        SetTitleBar(drag);

        var bottom = new Grid { Height = 56, Padding = new Thickness(12, 8, 12, 8), Background = new SolidColorBrush(Colors.Black) };
        _share.HorizontalAlignment = HorizontalAlignment.Left;
        _markup.HorizontalAlignment = HorizontalAlignment.Center;
        _save.HorizontalAlignment = HorizontalAlignment.Right;
        bottom.Children.Add(_share);
        bottom.Children.Add(_markup);
        bottom.Children.Add(_save);

        foreach (var (item, i) in items.Select((x, i) => (x, i))) _pages.Items.Add(Page(item, i));
        _pages.SelectionChanged += (_, _) => UpdateTitle();

        var root = new Grid { Background = new SolidColorBrush(Colors.Black), RequestedTheme = ElementTheme.Dark };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(_pages, 1);
        Grid.SetRow(bottom, 2);
        root.Children.Add(top);
        root.Children.Add(_pages);
        root.Children.Add(bottom);
        var esc = new KeyboardAccelerator { Key = VirtualKey.Escape };
        esc.Invoked += (_, e) => { e.Handled = true; Close(); };
        root.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        root.KeyboardAccelerators.Add(esc);
        Content = root;
        _pages.SelectedIndex = start;
        UpdateTitle();
        AppLog.Note("attachments", $"viewer opened at {start + 1} of {items.Count}");
    }

    private void UpdateTitle()
    {
        var i = Math.Max(0, _pages.SelectedIndex);
        _title.Text = _items.Count > 1 ? $"{i + 1} of {_items.Count}" : "";
        AutomationProperties.SetName(_pages, _items[i].Name);
    }

    private ScrollViewer Page(ViewerItem item, int index)
    {
        var image = new Image { Stretch = Stretch.Uniform };
        AutomationProperties.SetName(image, item.Name == "Photo" ? "Photo" : $"Photo, {item.Name}");
        var ring = new ProgressRing { IsActive = false, Width = 32, Height = 32 };
        var holder = new Grid();
        holder.Children.Add(image);
        holder.Children.Add(ring);
        var scroller = new ScrollViewer
        {
            ZoomMode = ZoomMode.Enabled, MinZoomFactor = 1, MaxZoomFactor = 5,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Auto, VerticalScrollMode = ScrollMode.Auto, Content = holder,
        };
        // The picture fits the space between the bars at 1×.
        scroller.SizeChanged += (_, e) => { holder.Width = e.NewSize.Width; holder.Height = e.NewSize.Height; };
        // A double-click toggles between fit and 2.5×, centred on the click.
        scroller.DoubleTapped += (_, e) =>
        {
            var p = e.GetPosition(holder);
            if (scroller.ZoomFactor > 1.01f) scroller.ChangeView(0, 0, 1);
            else scroller.ChangeView(p.X * 2.5 - scroller.ViewportWidth / 2, p.Y * 2.5 - scroller.ViewportHeight / 2, 2.5f);
        };
        _ = LoadAsync(item, index, holder, image, ring);
        return scroller;
    }

    private async Task LoadAsync(ViewerItem item, int index, Grid holder, Image image, ProgressRing ring)
    {
        var slow = Task.Delay(600);
        var load = item.Original();
        if (await Task.WhenAny(slow, load) == slow) ring.IsActive = true;
        try
        {
            var path = await load;
            _originals[index] = path;
            // The original decoded to at most 4096 px wide (screen pixels × 3 on the Mac).
            image.Source = await MediaActions.BitmapAsync(path, Math.Min(4096, (ImageHeader.PixelSizeOfFile(path)?.Width ?? 4096)));
        }
        catch (MediaLoadException e)
        {
            ring.Visibility = Visibility.Collapsed;
            holder.Children.Add(new TextBlock
            {
                Text = e.Kind == MediaLoadException.Kinds.TooLarge ? "Photo too large to load" : "Couldn’t load photo",
                Foreground = new SolidColorBrush(Colors.White), HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        catch (Exception e) { AppLog.Error("attachments", e); }
        finally { ring.IsActive = false; }
    }

    private async Task<(string Path, string Name)?> CurrentOriginal()
    {
        var i = Math.Max(0, _pages.SelectedIndex);
        if (_originals.TryGetValue(i, out var known)) return (known, _items[i].Name);
        try { return (await _items[i].Original(), _items[i].Name); }
        catch (Exception e) { AppLog.Error("attachments", e); return null; }
    }

    private XamlRoot? Root => Content?.XamlRoot;

    private async Task SaveAsync()
    {
        if (await CurrentOriginal() is not { } original)
        {
            await MediaActions.FailureAsync(Root, "Couldn’t Save", "Couldn’t reach your gateway. Try again.", SaveAsync);
            return;
        }
        var (path, name) = original;
        try
        {
            if (!await MediaActions.SaveAsAsync(path, name, this)) return;
            // "Saved" with a check for 1.8 s.
            _save.Content = Label("", "Saved");
            AutomationProperties.SetName(_save, "Saved");
            await Task.Delay(1800);
            _save.Content = Label("", "Save");
            AutomationProperties.SetName(_save, "Save");
        }
        catch (Exception e)
        {
            AppLog.Error("attachments", e);
            await MediaActions.FailureAsync(Root, "Couldn’t Save", e.Message, SaveAsync);
        }
    }

    private async Task ShareAsync()
    {
        if (await CurrentOriginal() is not { } original)
        {
            await MediaActions.FailureAsync(Root, "Couldn’t Share", "Couldn’t reach your gateway. Try again.", ShareAsync);
            return;
        }
        var (path, name) = original;
        try { await MediaActions.ShareAsync(path, name, this); }
        catch (Exception e)
        {
            AppLog.Error("attachments", e);
            await MediaActions.FailureAsync(Root, "Couldn’t Share", e.Message, ShareAsync);
        }
    }

    /// [image-markup] Opens the interactive markup editor on the current photo (App/Chat/Viewer/MediaViewerController.swift
    /// `openMarkup`): Send to Chat attaches the flattened PNG and populates the edit prompt in the open chat.
    private async Task MarkupAsync()
    {
        if (Root is not { } root) return;
        if (await CurrentOriginal() is not { } original)
        {
            await MediaActions.FailureAsync(Root, "Couldn’t Open Mark Up", "Couldn’t reach your gateway. Try again.", MarkupAsync);
            return;
        }
        var (path, name) = original;
        var canSend = ChatAttachments.Current != null;
        var result = await ImageMarkupDialog.ShowAsync(root, path, name, this, canSendToChat: canSend);
        if (result == null) return;
        try
        {
            if (result.Prompt.Length > 0 && MediaContext.Current is { } mc)
                mc.Center.SetText(mc.Session.DraftScope, mc.Profile, result.Prompt);
            if (ChatAttachments.Current is { } chat)
                await chat.AddPickedFilesAsync([new PickedItem(result.FlattenedPath, result.FileName, PickSource.Photo)]);
            Close();
        }
        catch (Exception e)
        {
            AppLog.Error("attachments", e);
            await MediaActions.FailureAsync(Root, "Couldn’t Attach Markup", e.Message, MarkupAsync);
        }
    }
}
