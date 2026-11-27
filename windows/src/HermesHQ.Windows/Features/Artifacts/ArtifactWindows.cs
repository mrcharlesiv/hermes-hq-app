using Hermes.Core.Artifacts;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.System;

namespace HermesHQ.Features.Artifacts;

/// A file, an HTML page a bot made or a Markdown note in a window of its own (App/Mac/MacFileWindow.swift; owner
/// 2026-11-09: "The way the Mac app opens up files like spreadsheets in a pop up is absolutely awful"; [mac-pages] owner
/// 2026-11-16): nearly as big as the main window, resizable, beside the chat if you like, a step down and right of the
/// file windows already open. Its bar names the file and has Open in <the app Windows opens it with>, Share… and Save
/// As…. Esc and Ctrl+W close it, not the main window's chat. The same file or page opened again brings its window
/// forward (a page shows the page just made). A file gone from this PC, or a window that didn't come, says so over the
/// main window in the Mac's words. Nothing is kept, so none reopens at the next launch. The decisions are
/// Hermes.Core/Artifacts/FileWindows.cs.
internal sealed partial class ArtifactFileWindow : Window
{
    private readonly TextBlock _title = new() { FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly StackPanel _buttons = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly Grid _root = new() { Background = Look.Brush("SolidBackgroundFillColorBaseBrush") };
    private UIElement? _body;

    /// A file on this PC (a spreadsheet, a PDF, any file): its window, or the one already showing it brought forward.
    public static void Show(string path, string name, ArtifactOpeningKind kind)
    {
        var result = Registry.OpenFile(path, name, File.Exists, _ =>
        {
            var w = new ArtifactFileWindow();
            w.ShowContent(name, path, FileBody(path, name, kind));
            return w;
        });
        Settle(result, kind.ToString());
    }

    /// A live page or a note (MacFileWindow.open(page:title:key:)). `file`: its copy on this PC, for the bar's Open
    /// in, Share… and Save As….
    public static void ShowPage(string key, string title, string? file, Func<UIElement> page)
    {
        var result = Registry.OpenPage(key, title, _ =>
        {
            var w = new ArtifactFileWindow();
            w.ShowContent(title, file, page());
            return w;
        });
        if (result is { Outcome: FileWindowOutcome.BroughtForward, Window: { } shown })
        {
            try { shown.ShowContent(title, file, page()); }   // FileSceneDelegate.scene(_:continue:): the page just made
            catch (Exception e) { ArtifactActions.Log($"page window: couldn't show the new page ({e.GetType().Name})"); }
        }
        Settle(result, "page");
    }

    /// A file opened from a chat, a tile or a bot's files (MediaActions.OpenAsync), as FilePreviewPresenter.present
    /// routes it: a page live, a note formatted, a PDF's pages or a text file in a window of its own. False: nothing
    /// here draws it, and it goes to its own app as before. `gatewayPath`: where it lives on the bot's computer.
    public static bool OpenRouted(string path, string name, string? gatewayPath)
    {
        if (!File.Exists(path))
        {
            ArtifactActions.Log("file window: the file isn't there");
            CouldNotOpen(FileWindowWords.Gone(name));
            return true;
        }
        var length = new FileInfo(path).Length;
        var shows = FileWindowRoute.For(name, length);
        if (shows == FileWindowShows.OwnApp) shows = FileWindowRoute.For(Path.GetFileName(path), length);
        switch (shows)
        {
            case FileWindowShows.Page:
                ShowPage(FileWindowKey.Page(gatewayPath, path), name, path, () => new ArtifactHtmlView(path, "") { Title = name });
                return true;
            case FileWindowShows.Note:
                ShowPage(FileWindowKey.Page(gatewayPath, path), name, path,
                    () => new ArtifactTextView(true, ct => File.ReadAllTextAsync(path, ct)) { Title = name });
                return true;
            case FileWindowShows.Pdf:
                Show(path, name, ArtifactOpeningKind.Pdf);
                return true;
            case FileWindowShows.Text:
                Show(path, name, ArtifactOpeningKind.Text);
                return true;
            case FileWindowShows.Table:
                // [WIN-FILE-DELIMITED] A .csv or .tsv in the app's own table (MacFileWindow.viewer); one it can't read
                // (nothing in it, not what its mark says) goes to its own app as before.
                if (DelimitedFile.Read(path, name) is not { } sheet) return false;
                ShowTable(path, name, sheet);
                return true;
            default:
                return false;
        }
    }

    /// A delimited file already read: its table in the file's window (the same window as `Show` for that path).
    private static void ShowTable(string path, string name, DelimitedSheet sheet)
    {
        var result = Registry.OpenFile(path, name, File.Exists, _ =>
        {
            var w = new ArtifactFileWindow();
            w.ShowContent(name, path, new DelimitedTableView(sheet, name));
            return w;
        });
        Settle(result, "table");
    }

    private static void Settle(FileWindowResult<ArtifactFileWindow> result, string what)
    {
        switch (result.Outcome)
        {
            case FileWindowOutcome.Opened:
                ArtifactActions.Log($"file window: open ({what})");
                result.Window!.Activate();
                break;
            case FileWindowOutcome.BroughtForward:
                ArtifactActions.Log($"file window: to the front ({what})");
                result.Window!.AppWindow.Show(true);
                result.Window.Activate();
                break;
            default:
                ArtifactActions.Log($"file window: couldn't open ({result.Outcome})");
                CouldNotOpen(result.Alert ?? "");
                break;
        }
    }

    /// "Couldn’t Open File" over the main window (MacFileWindow.couldNotOpen).
    private static void CouldNotOpen(string message) =>
        _ = ArtifactActions.AlertAsync(App.Window?.Content?.XamlRoot, FileWindowWords.CouldntOpenTitle, message);

    private static UIElement FileBody(string path, string name, ArtifactOpeningKind kind) => kind switch
    {
        ArtifactOpeningKind.Pdf => new PdfPagesView(path),
        ArtifactOpeningKind.Html => new ArtifactHtmlView(path, "") { Title = name },
        ArtifactOpeningKind.Text => new ArtifactTextView(false, ct => File.ReadAllTextAsync(path, ct)) { Title = name },
        // [WIN-FILE-DELIMITED] The Artifacts page's own Show of a .csv or .tsv: its table when it reads, else as before.
        _ when DelimitedFile.Read(path, name) is { } sheet => new DelimitedTableView(sheet, name),
        _ => Look.State("\uE7C3", name, $"{Size(path)}. Windows opens it in its own app.",
            (FileWindowWords.OpenIn(DefaultApp(path)), () => _ = OpenInDefaultAppAsync(path, name, null))),
    };

    private ArtifactFileWindow()
    {
        ExtendsContentIntoTitleBar = true;
        Place();
        var bar = new Grid { Height = 48, Padding = new Thickness(16, 6, 140, 6), ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var drag = new Grid { Background = new SolidColorBrush(Colors.Transparent) };
        bar.Children.Add(drag);
        bar.Children.Add(_title);
        Grid.SetColumn(_buttons, 1);
        bar.Children.Add(_buttons);
        SetTitleBar(drag);
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.Children.Add(bar);
        AutomationProperties.SetAutomationId(_root, "file.window");
        AddCloseKeys(_root, Close, () => _root.XamlRoot is { } x && VisualTreeHelper.GetOpenPopupsForXamlRoot(x).Count > 0);
        Content = _root;
        Closed += (_, _) =>
        {
            (_body as ArtifactHtmlView)?.Close();   // what its page still had under way is dropped, not a failure
            Registry.Closed(this);
            ArtifactActions.Log("file window: closed");
        };
    }

    /// What the window shows (the CI's file-windows walk reads a page's Preview from it).
    internal UIElement? Body => _body;

    /// The window's title, its bar's buttons and what it shows.
    private void ShowContent(string name, string? file, UIElement body)
    {
        Title = name;   // the taskbar and Alt+Tab name it
        _title.Text = name;
        _buttons.Children.Clear();
        // [WIN-PAGE-ZOOM] − 100 % + for a page (HTMLPageSheet's bar), the level the previews share.
        if (body is ArtifactHtmlView) _buttons.Children.Add(new PageZoomControls(compact: false));
        if (file != null && File.Exists(file))
        {
            var app = DefaultApp(file);
            Button(FileWindowWords.OpenIn(app), "\uE8A7", "file.window.open-in", () => OpenInDefaultAppAsync(file, name, app));
            Button(ArtifactPageWords.Share, "\uE72D", "file.window.share", () => ArtifactActions.ShareFileAsync(file, name, this));
            Button(ArtifactPageWords.SaveAs, "\uE74E", "file.window.save", () => ArtifactActions.SaveAsAsync(file, name, this));
        }
        if (_body != null)
        {
            _root.Children.Remove(_body);
            (_body as ArtifactHtmlView)?.Close();   // the page just made replaces it; its late work is dropped
        }
        _body = body;
        Grid.SetRow((FrameworkElement)body, 1);
        _root.Children.Add(body);
    }

    private void Button(string text, string glyph, string id, Func<Task> act)
    {
        var b = new Button { Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { new FontIcon { Glyph = glyph, FontSize = 14 }, new TextBlock { Text = text } } } };
        AutomationProperties.SetName(b, text);
        AutomationProperties.SetAutomationId(b, id);
        b.Click += async (_, _) =>
        {
            try { await act(); }
            catch (Exception e) { ArtifactActions.Log($"file window action failed: {e.GetType().Name}"); }
        };
        _buttons.Children.Add(b);
    }

    /// FileSceneDelegate.show: the main window's size less a little, down and right of it, inside the screen, a step
    /// on from the file windows already there.
    private void Place()
    {
        if (App.Window is not { } main) return;
        try
        {
            var m = main.AppWindow;
            var scale = main.Content?.XamlRoot?.RasterizationScale ?? 1;
            var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(m.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Nearest).WorkArea;
            var taken = Registry.Keys.Select(Registry.Find).OfType<ArtifactFileWindow>().Where(w => w != this)
                .Select(w => ((double)w.AppWindow.Position.X, (double)w.AppWindow.Position.Y)).ToList();
            var frame = FileWindowPlacement.Frame(new WindowFrame(m.Position.X, m.Position.Y, m.Size.Width, m.Size.Height), taken,
                new WindowFrame(area.X, area.Y, area.Width, area.Height), scale);
            AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32((int)frame.X, (int)frame.Y, (int)frame.Width, (int)frame.Height));
            if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter p)
            {
                p.PreferredMinimumWidth = (int)(FileWindowPlacement.MinimumWidth * scale);
                p.PreferredMinimumHeight = (int)(FileWindowPlacement.MinimumHeight * scale);
            }
        }
        catch (Exception e) { ArtifactActions.Log($"file window: placing failed ({e.GetType().Name})"); }
    }

    private static string Size(string path)
    {
        var bytes = new FileInfo(path).Length;
        return bytes < 1024 ? $"{bytes} bytes" : bytes < 1 << 20 ? $"{bytes / 1024.0:0.#} KB" : $"{bytes / 1048576.0:0.#} MB";
    }

    /// MacFileWindow.openInDefaultApp: the app gets a copy, so its edits and the kept copy keep apart. Refused: the
    /// Mac's "<app> didn’t open it. Share… or Save As… still can."
    private static async Task OpenInDefaultAppAsync(string path, string name, string? app)
    {
        var copy = FileWindowCopies.ForOtherApp(Path.GetTempPath(), name.Length > 0 ? name : Path.GetFileName(path), Guid.NewGuid());
        var opened = false;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(path, copy, overwrite: true);
            opened = await Launcher.LaunchFileAsync(await global::Windows.Storage.StorageFile.GetFileFromPathAsync(copy));
        }
        catch (Exception e) { ArtifactActions.Log($"file window: couldn't hand it to another app ({e.GetType().Name})"); }
        ArtifactActions.Log($"file window: handed to its app ({opened})");
        if (!opened) CouldNotOpen(FileWindowWords.AppDidntOpen(app));
    }

    /// The app Windows opens `path` with, by its friendly name ("Excel"); null when none takes it.
    internal static string? DefaultApp(string path)
    {
        var ext = Path.GetExtension(path);
        if (ext.Length == 0) return null;
        try
        {
            uint size = 0;
            if (AssocQueryString(AssocfInitIgnoreUnknown, AssocstrFriendlyAppName, ext, null, null, ref size) != 1 || size == 0) return null;
            var text = new System.Text.StringBuilder((int)size);
            if (AssocQueryString(AssocfInitIgnoreUnknown, AssocstrFriendlyAppName, ext, null, text, ref size) != 0) return null;
            var name = text.ToString().Trim();
            return name.Length == 0 ? null : name;
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { return null; }
    }

    private const uint AssocfInitIgnoreUnknown = 0x400, AssocstrFriendlyAppName = 4;

    [System.Runtime.InteropServices.DllImport("shlwapi.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int AssocQueryString(uint flags, uint str, string assoc, string? extra, System.Text.StringBuilder? output, ref uint outputSize);

    /// Esc and Ctrl+W close a file's or picture's window, never the main window's chat (FileWindowKeys.Route): with
    /// something over it (a dialog), Esc is left to that and Ctrl+W is held.
    public static void AddCloseKeys(UIElement root, Action close, Func<bool>? somethingOver = null)
    {
        void Route(FileWindowKeyPress press, KeyboardAcceleratorInvokedEventArgs e)
        {
            switch (FileWindowKeys.Route(press, fileWindowInFront: true, somethingOver?.Invoke() == true))
            {
                case FileWindowKeyAction.CloseWindow: e.Handled = true; close(); break;
                case FileWindowKeyAction.Nothing: e.Handled = true; break;
                default: e.Handled = false; break;   // what is over it closes on its own Escape
            }
        }
        var esc = new KeyboardAccelerator { Key = VirtualKey.Escape };
        esc.Invoked += (_, e) => Route(FileWindowKeyPress.Escape, e);
        var w = new KeyboardAccelerator { Key = VirtualKey.W, Modifiers = VirtualKeyModifiers.Control };
        w.Invoked += (_, e) => Route(FileWindowKeyPress.CtrlW, e);
        root.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        root.KeyboardAccelerators.Add(esc);
        root.KeyboardAccelerators.Add(w);
    }
}

/// The image viewer (App/Pages/Artifacts/ArtifactImageViewer.swift; docs/spec/1x-pages.md §5.6), in its own window:
/// black, paging across the segment's pictures (← and →), zoom (Ctrl+wheel, double-click), the picture's name and
/// "2 of 5" at the top with Done; Share, Show in Chat and Info under it. A picture on another site that wasn't fetched
/// says so and offers Open.
internal sealed class ArtifactImageWindow : Window
{
    private static ArtifactImageWindow? _open;
    private readonly IReadOnlyList<ArtifactRecord> _records;
    private readonly ArtifactPreviews _previews;
    private readonly FlipView _pages = new() { Background = new SolidColorBrush(Colors.Black) };
    private readonly TextBlock _title = new() { Foreground = new SolidColorBrush(Colors.White), FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock _subtitle = new() { Foreground = new SolidColorBrush(Colors.Gray), FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center };

    /// [WIN-EXIT-STOWED-PROBE] The quit closes the image viewer before the main window goes.
    internal static void CloseOpen() => _open?.Close();

    public static void Show(IReadOnlyList<ArtifactRecord> records, int index, ArtifactPreviews previews)
    {
        if (records.Count == 0) return;
        _open?.Close();
        _open = new ArtifactImageWindow(records, Math.Clamp(index, 0, records.Count - 1), previews);
        _open.Activate();
    }

    private ArtifactRecord Shown => _records[Math.Max(0, _pages.SelectedIndex)];

    private static Button BarButton(string glyph, string text, string id)
    {
        var b = new Button
        {
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { new FontIcon { Glyph = glyph, FontSize = 14 }, new TextBlock { Text = text } } },
            Foreground = new SolidColorBrush(Colors.White), CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(46, 255, 255, 255)), Padding = new Thickness(12, 6, 14, 6),
        };
        AutomationProperties.SetName(b, text);
        AutomationProperties.SetAutomationId(b, id);
        return b;
    }

    private ArtifactImageWindow(IReadOnlyList<ArtifactRecord> records, int start, ArtifactPreviews previews)
    {
        _records = records;
        _previews = previews;
        Title = records[start].Label;
        ExtendsContentIntoTitleBar = true;
        if (App.Window is { } main)
        {
            var size = main.AppWindow.Size;
            AppWindow.Resize(new Windows.Graphics.SizeInt32(Math.Max(640, size.Width - 80), Math.Max(480, size.Height - 80)));
            AppWindow.Move(new Windows.Graphics.PointInt32(main.AppWindow.Position.X + 40, main.AppWindow.Position.Y + 40));
        }
        var done = BarButton("", "Done", "artifact.image.close");
        done.Click += (_, _) => Close();
        var share = BarButton("\uE72D", "Share", "artifact.image.share");
        share.Click += async (_, _) => await ShareAsync();
        var chat = BarButton("\uE8BD", ArtifactPageWords.ShowInChat, "artifact.image.chat");
        chat.Click += (_, _) => { var r = Shown; Close(); ArtifactActions.ShowInChat(r); };
        var info = BarButton("\uE946", "Info", "artifact.image.info");
        info.Click += async (_, _) => await InfoAsync();

        var top = new Grid { Height = 52, Padding = new Thickness(12, 6, 12, 6), Background = new SolidColorBrush(Colors.Black) };
        var drag = new Grid { Background = new SolidColorBrush(Colors.Transparent), Margin = new Thickness(0, 0, 220, 0) };
        top.Children.Add(drag);
        SetTitleBar(drag);
        top.Children.Add(new StackPanel { VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false, Children = { _title, _subtitle } });
        done.HorizontalAlignment = HorizontalAlignment.Right;
        done.Margin = new Thickness(0, 0, 140, 0);
        top.Children.Add(done);

        var bottom = new Grid { Height = 56, Padding = new Thickness(12, 8, 12, 8), Background = new SolidColorBrush(Colors.Black) };
        share.HorizontalAlignment = HorizontalAlignment.Left;
        chat.HorizontalAlignment = HorizontalAlignment.Center;
        info.HorizontalAlignment = HorizontalAlignment.Right;
        bottom.Children.Add(share);
        bottom.Children.Add(chat);
        bottom.Children.Add(info);

        foreach (var record in records) _pages.Items.Add(Page(record));
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
        ArtifactFileWindow.AddCloseKeys(root, Close, () => root.XamlRoot is { } x && VisualTreeHelper.GetOpenPopupsForXamlRoot(x).Count > 0);
        Content = root;
        _pages.SelectedIndex = start;
        UpdateTitle();
        Closed += (_, _) => { if (_open == this) _open = null; };
    }

    private void UpdateTitle()
    {
        var i = Math.Max(0, _pages.SelectedIndex);
        _title.Text = _records[i].Label;
        Title = _records[i].Label;
        _subtitle.Text = _records.Count > 1 ? $"{i + 1} of {_records.Count}" : "";
        _subtitle.Visibility = _records.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    private ScrollViewer Page(ArtifactRecord record)
    {
        var image = new Image { Stretch = Stretch.Uniform };
        AutomationProperties.SetName(image, record.Label);
        var ring = new ProgressRing { IsActive = true, Width = 32, Height = 32 };
        var failure = new StackPanel { Spacing = 14, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed, MaxWidth = 420 };
        var holder = new Grid();
        holder.Children.Add(image);
        holder.Children.Add(ring);
        holder.Children.Add(failure);
        var scroller = new ScrollViewer
        {
            ZoomMode = ZoomMode.Enabled, MinZoomFactor = 1, MaxZoomFactor = 5, Content = holder,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Auto, VerticalScrollMode = ScrollMode.Auto,
        };
        scroller.SizeChanged += (_, e) => { holder.Width = e.NewSize.Width; holder.Height = e.NewSize.Height; };
        scroller.DoubleTapped += (_, e) =>
        {
            var p = e.GetPosition(holder);
            if (scroller.ZoomFactor > 1.01f) scroller.ChangeView(0, 0, 1);
            else scroller.ChangeView(p.X * 2.5 - scroller.ViewportWidth / 2, p.Y * 2.5 - scroller.ViewportHeight / 2, 2.5f);
        };
        _ = LoadAsync(record, image, ring, failure);
        return scroller;
    }

    private async Task LoadAsync(ArtifactRecord record, Image image, ProgressRing ring, StackPanel failure)
    {
        try
        {
            var file = await _previews.FullAsync(record);
            var bitmap = new BitmapImage();
            using (var stream = File.OpenRead(file)) await bitmap.SetSourceAsync(stream.AsRandomAccessStream());
            image.Source = bitmap;
        }
        catch (Exception e)
        {
            failure.Children.Add(new TextBlock { Text = ArtifactFiles.FailureText(e, image: true), Foreground = new SolidColorBrush(Colors.White), TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center });
            // A picture on another site (not fetched here): Open hands its link to the browser.
            if (e is RemoteImageRefusedException)
            {
                var open = BarButton("\uE774", ArtifactPageWords.Open, "artifact.image.open");
                open.HorizontalAlignment = HorizontalAlignment.Center;
                open.Click += (_, _) => ArtifactActions.OpenOutside(record.Value);
                failure.Children.Add(open);
            }
            failure.Visibility = Visibility.Visible;
        }
        ring.IsActive = false;
        ring.Visibility = Visibility.Collapsed;
    }

    private async Task ShareAsync()
    {
        var record = Shown;
        if (!ArtifactFiles.IsGatewayFile(record)) { ArtifactActions.ShareLink(record.Value, this); return; }
        try { await ArtifactActions.ShareFileAsync(await _previews.FullAsync(record), record.Label, this); }
        catch (Exception e)
        {
            await ArtifactActions.AlertAsync(Content.XamlRoot, ArtifactPageWords.CouldntDo("Share", record.Label), ArtifactFiles.FailureText(e, image: true));
        }
    }

    /// Info: the name, its chat, when, the path; Copy Path.
    private async Task InfoAsync()
    {
        var record = Shown;
        var dialog = new ContentDialog
        {
            Title = "Info",
            Content = new TextBlock
            {
                Text = string.Join("\n", record.Label, record.SessionTitle, ArtifactListWords.RelativeDateTime(record.Timestamp), record.Value),
                TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
            },
            PrimaryButtonText = ArtifactPageWords.CopyPath, CloseButtonText = "Done", DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot, RequestedTheme = ElementTheme.Dark,
        };
        try
        {
            if (await dialog.ShowAsync() == ContentDialogResult.Primary) ArtifactActions.Copy(record.Value);
        }
        catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException) { }
    }
}
