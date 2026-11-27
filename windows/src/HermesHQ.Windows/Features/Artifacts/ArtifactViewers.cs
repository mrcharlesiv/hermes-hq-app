using Hermes.Core.Artifacts;
using HermesHQ.Controls;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Web.WebView2.Core;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;

namespace HermesHQ.Features.Artifacts;

/// Shared look for the viewers.
internal static class Look
{
    public static Brush Brush(string key) => ThemeBrushes.Get(key);
    public static FontFamily Mono => (FontFamily)Application.Current.Resources["CodeFont"];

    public static TextBlock Text(string text, double size = 14, string brush = "TextFillColorPrimaryBrush", bool semibold = false) => new()
    {
        Text = text, FontSize = size, Foreground = Brush(brush), TextWrapping = TextWrapping.Wrap,
        FontWeight = semibold ? FontWeights.SemiBold : FontWeights.Normal,
    };

    /// The empty or failed state of a page or viewer: a glyph, a title, words, and up to two buttons.
    public static StackPanel State(string glyph, string title, string? words, (string Text, Action Act)? primary = null,
        (string Text, Action Act)? secondary = null)
    {
        var panel = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 420, Margin = new Thickness(24) };
        panel.Children.Add(new FontIcon { Glyph = glyph, FontSize = 40, Foreground = Brush("TextFillColorTertiaryBrush") });
        var head = Text(title, 18, semibold: true);
        head.TextAlignment = TextAlignment.Center;
        head.HorizontalAlignment = HorizontalAlignment.Center;
        panel.Children.Add(head);
        if (!string.IsNullOrEmpty(words))
        {
            var body = Text(words, 13, "TextFillColorSecondaryBrush");
            body.TextAlignment = TextAlignment.Center;
            body.HorizontalAlignment = HorizontalAlignment.Center;
            panel.Children.Add(body);
        }
        if (primary is { } p)
        {
            var b = new Button { Content = p.Text, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0),
                Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            b.Click += (_, _) => p.Act();
            panel.Children.Add(b);
        }
        if (secondary is { } s)
        {
            var b = new Button { Content = s.Text, HorizontalAlignment = HorizontalAlignment.Center };
            b.Click += (_, _) => s.Act();
            panel.Children.Add(b);
        }
        return panel;
    }

    /// Preview | Source, as the Mac's segmented switch beside Share.
    public static StackPanel Modes(int selected, Action<int> picked) =>
        Segments(["Preview", "Source"], selected, picked, "artifact.text.mode");

    /// A row of segments whose chosen one stands on a raised thumb (the Mac's segmented control).
    public static StackPanel Segments(IReadOnlyList<string> titles, int selected, Action<int> picked, string id)
    {
        var strip = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 2, Padding = new Thickness(2), CornerRadius = new CornerRadius(8),
            Background = Brush("ControlAltFillColorSecondaryBrush"), BorderBrush = Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1), VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAutomationId(strip, id);
        void Paint()
        {
            for (var i = 0; i < strip.Children.Count; i++)
            {
                var b = (Button)strip.Children[i];
                var on = i == selected;
                b.Background = on ? Brush("ControlFillColorDefaultBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
                b.BorderBrush = on ? Brush("ControlStrokeColorDefaultBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
                b.FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal;
                AutomationProperties.SetItemStatus(b, on ? "selected" : "");
            }
        }
        for (var i = 0; i < titles.Count; i++)
        {
            var index = i;
            var b = new Button
            {
                Content = titles[i], Padding = new Thickness(14, 3, 14, 4), MinWidth = 56, CornerRadius = new CornerRadius(6),
                BorderThickness = new Thickness(1), FontSize = 13,
            };
            AutomationProperties.SetName(b, titles[i]);
            b.Click += (_, _) =>
            {
                if (selected == index) return;
                selected = index;
                Paint();
                picked(index);
            };
            strip.Children.Add(b);
        }
        Paint();
        return strip;
    }

    public static async Task EnsureAsync(WebView2 web)
    {
        await web.EnsureCoreWebView2Async(await WebViewEnv.GetAsync());
    }

    /// A page's own links stay in it; a web link opens in the browser; nothing else is followed (the Mac's PageLinkGuard).
    public static void Guard(WebView2 web, string file)
    {
        var page = new Uri(file).AbsoluteUri;
        web.CoreWebView2.NavigationStarting += (_, e) =>
        {
            if (e.Uri.StartsWith(page, StringComparison.OrdinalIgnoreCase) || e.Uri.StartsWith("about:", StringComparison.Ordinal)
                || e.Uri.StartsWith("data:", StringComparison.Ordinal)) return;
            e.Cancel = true;
            if (e.IsUserInitiated) ArtifactActions.OpenOutside(e.Uri);
        };
        web.CoreWebView2.NewWindowRequested += (_, e) =>
        {
            e.Handled = true;
            ArtifactActions.OpenOutside(e.Uri);
        };
    }
}

/// What the file pane shows for one file (the Mac's text viewer, pushed on the pane's stack): its title, whether it
/// switches Preview | Source, what Share hands over, and whether it opens in a window of its own.
internal abstract class ArtifactViewer : Grid
{
    public required string Title { get; init; }
    public ArtifactRecord? Record { get; init; }
    public virtual bool HasModes => false;
    public int Mode { get; protected set; }
    public bool IsReady { get; protected set; }
    /// The file on this PC for Share and Save As (null: nothing to share yet).
    public Func<Task<string?>>? ShareFile { get; set; }
    /// Open in Window (an HTML page in a window of its own).
    public Action? OpenInWindow { get; set; }
    /// Something the bar shows changed (loaded, failed).
    public event Action? Changed;
    protected void Notify() => Changed?.Invoke();
    public virtual void SetMode(int mode) { }
}

/// A file's text, read-only (ArtifactTextViewController.swift): Markdown with Preview (front matter as facts) | Source;
/// code and text monospaced, lines wrapping at words. A link in a note goes to `LinkOpener` (linked notes).
internal sealed class ArtifactTextView : ArtifactViewer
{
    private readonly bool _markdown;
    private readonly Func<CancellationToken, Task<string>> _load;
    private readonly ScrollViewer _scroller = new() { HorizontalScrollMode = ScrollMode.Disabled, Padding = new Thickness(24, 16, 24, 24) };
    private readonly StackPanel _content = new() { Spacing = 6, MaxWidth = 860, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly ProgressRing _spinner = new() { IsActive = true, Width = 28, Height = 28 };
    private readonly TextBlock _loadingLabel = Look.Text("", 13, "TextFillColorSecondaryBrush");
    private readonly StackPanel _loading = new() { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private string _text = "";
    private CancellationTokenSource? _life;

    public string? LoadingText { get; init; }
    /// The failed state's title ("Couldn’t open plan.md here."); null = "Couldn’t Open This File".
    public string? FailureTitle { get; init; }
    /// A heading to scroll to once the note is drawn (a link "plan.md#usage").
    public string? PendingFragment { get; set; }
    /// A link to another file, as written, with its `#fragment`.
    public Action<string, string?>? LinkOpener { get; set; }
    /// Offered when the text can't be read (not for a missing file): the Mac's Open in Quick Look.
    public Func<Task>? OpenElsewhere { get; set; }
    /// The last heading a link scrolled to.
    public string? LastFragment { get; private set; }

    public override bool HasModes => _markdown && IsReady;

    public ArtifactTextView(bool markdown, Func<CancellationToken, Task<string>> load)
    {
        _markdown = markdown;
        _load = load;
        _scroller.Content = _content;
        Children.Add(_scroller);
        _loading.Children.Add(_spinner);
        _loading.Children.Add(_loadingLabel);
        Children.Add(_loading);
        AutomationProperties.SetAutomationId(this, "artifact.text");
        Loaded += (_, _) => { if (!IsReady && _life == null) Reload(); };
        Unloaded += (_, _) => { if (!IsReady) { _life?.Cancel(); _life = null; } };
    }

    public void Reload()
    {
        _life?.Cancel();
        _life = new CancellationTokenSource();
        var token = _life.Token;
        _loadingLabel.Text = LoadingText ?? "";
        _loadingLabel.Visibility = LoadingText == null ? Visibility.Collapsed : Visibility.Visible;
        _loading.Visibility = Visibility.Visible;
        _spinner.IsActive = true;
        _content.Children.Clear();
        foreach (var old in Children.OfType<StackPanel>().Where(p => p.Tag as string == "failure").ToList()) Children.Remove(old);
        _ = LoadAsync(token);
    }

    private async Task LoadAsync(CancellationToken token)
    {
        try
        {
            _text = await _load(token);
            if (token.IsCancellationRequested) return;
            IsReady = true;
            _loading.Visibility = Visibility.Collapsed;
            Render();
            Notify();
            if (PendingFragment is { } fragment)
            {
                PendingFragment = null;
                DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => ScrollTo(fragment));
            }
        }
        catch (Exception e) when (!token.IsCancellationRequested)
        {
            _loading.Visibility = Visibility.Collapsed;
            ShowFailure(e);
            Notify();
        }
        catch (OperationCanceledException) { }
    }

    private void ShowFailure(Exception error)
    {
        (string, Action)? other = OpenElsewhere != null && !ArtifactFiles.IsMissing(error)
            ? (ArtifactPageWords.OpenInDefaultApp, () => _ = OpenElsewhere()) : null;
        var state = Look.State("\uE9CE", FailureTitle ?? ArtifactPageWords.CouldntOpenFile, ArtifactFiles.FailureText(error, image: false),
            (ArtifactPageWords.TryAgain, Reload), other);
        state.Tag = "failure";
        Children.Add(state);
    }

    public override void SetMode(int mode)
    {
        if (mode == Mode) return;
        Mode = mode;
        Render();
    }

    private void Render()
    {
        _content.Children.Clear();
        if (!_markdown || Mode == 1)
        {
            // Code and text: monospaced, lines wrapping at words (the Source of a note too).
            var source = new TextBlock
            {
                Text = _text, FontFamily = Look.Mono, FontSize = 13, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                Foreground = Look.Brush("TextFillColorPrimaryBrush"),
            };
            AutomationProperties.SetAutomationId(source, "artifact.text.source");
            _content.Children.Add(source);
            return;
        }
        var (facts, body) = ArtifactLinks.FrontMatter(_text);
        if (facts.Count > 0)
        {
            var box = new Grid
            {
                ColumnSpacing = 12, RowSpacing = 4, Padding = new Thickness(12, 10, 12, 10), CornerRadius = new CornerRadius(8),
                Background = Look.Brush("CardBackgroundFillColorSecondaryBrush"), Margin = new Thickness(0, 0, 0, 8),
            };
            box.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            box.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            for (var i = 0; i < facts.Count; i++)
            {
                box.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var key = Look.Text(facts[i].Key, 13, "TextFillColorSecondaryBrush");
                var value = Look.Text(facts[i].Value, 13);
                Grid.SetRow(key, i); Grid.SetRow(value, i); Grid.SetColumn(value, 1);
                box.Children.Add(key); box.Children.Add(value);
            }
            _content.Children.Add(box);
        }
        MarkdownRenderer.Render(body, _content, onLink: Follow);
    }

    private void Follow(string destination)
    {
        var link = ArtifactLinks.Classify(destination);
        switch (link.Kind)
        {
            case ArtifactLinkKind.Hash: ScrollTo(link.Fragment!); break;
            case ArtifactLinkKind.File: LinkOpener?.Invoke(link.Target!, link.Fragment); break;
            case ArtifactLinkKind.External: ArtifactActions.OpenOutside(link.Url!.AbsoluteUri); break;
        }
    }

    /// Scrolls the Preview to the heading a `#fragment` names; false when the note has no such heading.
    public bool ScrollTo(string fragment)
    {
        if (!_markdown || Mode == 1) return false;
        var wanted = ArtifactLinks.HeadingSlug(fragment);
        var headings = ArtifactLinks.Headings(ArtifactLinks.FrontMatter(_text).Body);
        var index = headings.FindIndex(h => h.Id == fragment || h.Id == wanted);
        if (index < 0) return false;
        var heading = headings[index].Text;
        // The same words may stand in a paragraph above: the nth paragraph that is exactly the heading.
        var nth = headings.Take(index).Count(h => h.Text == heading);
        var seen = 0;
        foreach (var block in _content.Children.OfType<RichTextBlock>())
        {
            foreach (var paragraph in block.Blocks.OfType<Paragraph>())
            {
                if (Plain(paragraph.Inlines).Trim() != heading) continue;
                if (seen++ != nth) continue;
                var rect = paragraph.ContentStart.GetCharacterRect(LogicalDirection.Forward);
                var at = block.TransformToVisual(_content).TransformPoint(new Windows.Foundation.Point(0, rect.Y));
                _scroller.ChangeView(null, Math.Max(0, at.Y - 12), null);
                LastFragment = fragment;
                AutomationProperties.SetItemStatus(this, "#" + fragment);
                return true;
            }
        }
        return false;
    }

    private static string Plain(InlineCollection inlines) => string.Concat(inlines.Select(i => i switch
    {
        Run r => r.Text,
        Span s => Plain(s.Inlines),
        _ => "",
    }));
}

/// An HTML page (ArtifactTextViewController with `htmlPreview`): Preview is the page live in WebView2 (its scripts
/// run, its links go to the browser) | Source its text. Open in Window shows it in a window of its own.
/// What it does as the web view comes, the page loads, the view leaves the screen or its window closes is
/// Hermes.Core/Artifacts/PagePreview.cs: it is ready only once the page drew; until then a spinner says it's loading;
/// a page that didn't draw in a view still on show says so, with Try Again and its Source; the late work of a view
/// that's gone is dropped, not called a failure.
internal sealed class ArtifactHtmlView : ArtifactViewer
{
    private readonly string _preview;
    private readonly PagePreviewLife _life = new();
    private readonly Grid _page = new();
    /// [WIN-PAGE-ZOOM] The web view's own room: a canvas never squeezes or layout-clips it, so laid out over the zoom
    /// and drawn grown it fills `_page` exactly, which clips it.
    private readonly Canvas _room = new();
    private readonly ScrollViewer _source;
    private readonly TextBlock _sourceText;
    private readonly StackPanel _loading = new() { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressRing _spinner = new() { IsActive = true, Width = 28, Height = 28 };
    private WebView2? _web;
    private StackPanel? _failure;
    private bool _sourceRead;
    private IDisposable? _zoomWatch;

    public override bool HasModes => true;
    /// Where the Preview stands (the CI's file-windows walk waits on it; a drawn toolbar is not a drawn page).
    public PagePreviewPhase Phase => _life.Phase;
    public string? FailureReason => _life.Reason;
    /// [WIN-PAGE-ZOOM] What the page is drawn grown by now (the walk reads it; 1 at actual size).
    public double DrawnScale => (_web?.RenderTransform as ScaleTransform)?.ScaleX ?? 1;

    public ArtifactHtmlView(string previewFile, string sourceText)
    {
        _preview = previewFile;
        _sourceRead = sourceText.Length > 0;
        _sourceText = new TextBlock { Text = sourceText, FontFamily = Look.Mono, FontSize = 13, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        AutomationProperties.SetAutomationId(_sourceText, "artifact.text.source");
        _source = new ScrollViewer { Padding = new Thickness(24, 16, 24, 24), Visibility = Visibility.Collapsed, Content = _sourceText };
        _loading.Children.Add(_spinner);
        _loading.Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(_loading, "artifact.page.loading");
        Children.Add(_page);
        Children.Add(_source);
        Children.Add(_loading);
        Loaded += (_, _) =>
        {
            StartZoomWatch();
            Act(_life.OnScreen(_web?.CoreWebView2 != null));
        };
        _page.Children.Add(_room);
        _page.SizeChanged += (_, _) => PlaceWeb();
        AddZoomKeys();
        Unloaded += (_, _) =>
        {
            StopZoomWatch();
            var was = _life.Phase;
            _life.OffScreen();
            if (was == PagePreviewPhase.Loading) ShowLoading(false);
        };
    }

    /// Its window closed or the page just made replaced it (ArtifactFileWindow): what's under way is dropped and the
    /// web view let go.
    public void Close()
    {
        StopZoomWatch();
        _life.Close();
        ShowLoading(false);
        if (_web is { } web)
        {
            _web = null;
            _room.Children.Remove(web);
            try { web.Close(); }
            catch (Exception e) { ArtifactActions.Log($"page preview: closing its web view failed ({e.GetType().Name})"); }
        }
    }

    /// The page's own words, read from the live page (the walk's proof that the body isn't blank). Null: not drawn.
    public async Task<string?> PageTextAsync()
    {
        if (!_life.IsReady || _web?.CoreWebView2 is not { } core) return null;
        var json = await core.ExecuteScriptAsync("document.body ? document.body.innerText.slice(0, 400) : ''");
        try { return System.Text.Json.JsonSerializer.Deserialize<string>(json); }
        catch (System.Text.Json.JsonException) { return null; }
    }

    // [WIN-PAGE-ZOOM] The pages' one zoom level (Hermes.Core/Artifacts/PageZoom.cs): followed while this view is on
    // screen and its window open, so a stale or closed preview never touches its old web view.
    private void StartZoomWatch()
    {
        if (_life.Phase == PagePreviewPhase.Closed) return;
        _zoomWatch?.Dispose();
        _zoomWatch = PageZoomShared.Level.Watch(_ => PlaceWeb());
        PlaceWeb();
    }

    private void StopZoomWatch()
    {
        _zoomWatch?.Dispose();
        _zoomWatch = null;
    }

    /// The web view laid out in its room over the zoom and drawn grown by it (PageZoom.place), at native size: 100 %
    /// is the page's real size here. WinUI's WebView2 keeps its controller's ZoomFactor private, so the app's own XAML
    /// transform grows it; nothing runs in the page.
    private void PlaceWeb()
    {
        _page.Clip = new RectangleGeometry { Rect = new global::Windows.Foundation.Rect(0, 0, Math.Max(0, _page.ActualWidth), Math.Max(0, _page.ActualHeight)) };
        if (_web is not { } web) return;
        var (width, height, scale) = PageZoomSteps.Place(_page.ActualWidth, _page.ActualHeight, PageZoomShared.Level.Percent);
        web.Width = width;
        web.Height = height;
        web.RenderTransform = scale == 1 ? null : new ScaleTransform { ScaleX = scale, ScaleY = scale };
    }

    /// Ctrl+= / Ctrl+- / Ctrl+0 (and the keypad's) zoom the page while it has the keys (the Mac's ⌘+ ⌘− ⌘0); at an
    /// end of the range they do nothing, not the app's UI scale.
    private void AddZoomKeys()
    {
        foreach (var (key, by) in PageZoomKeys.All)
        {
            var a = new Microsoft.UI.Xaml.Input.KeyboardAccelerator
            {
                Key = (global::Windows.System.VirtualKey)key, Modifiers = global::Windows.System.VirtualKeyModifiers.Control, ScopeOwner = this,
            };
            a.Invoked += (_, e) =>
            {
                if (Mode != 0) return;   // the Source: the keys are the app's again
                e.Handled = true;
                PageZoomShared.Level.Change(by);
            };
            KeyboardAcceleratorPlacementMode = Microsoft.UI.Xaml.Input.KeyboardAcceleratorPlacementMode.Hidden;
            KeyboardAccelerators.Add(a);
        }
    }

    private void Act(PagePreviewDecision d)
    {
        switch (d.Step)
        {
            case PagePreviewStep.Start: _ = StartAsync(d.Attempt); break;
            case PagePreviewStep.Show:
                ShowLoading(false);
                IsReady = true;
                ArtifactActions.Log($"page preview: drawn ({_since.ElapsedMilliseconds} ms)");
                Notify();
                break;
            case PagePreviewStep.Fail:
                ShowFailure(d.Reason ?? PagePreviewWords.DidntLoad);
                break;
            case PagePreviewStep.Drop:
                ArtifactActions.Log($"page preview: late work dropped ({d.Reason})");
                break;
        }
    }

    // When the live attempt started: the log says where a slow page's time went (CI runs 45081613795 and 45089742433:
    // the run's first page window didn't draw in 30 s, every later one in under a second, run 45084955836's first in 9 s).
    private System.Diagnostics.Stopwatch _since = new();

    private async Task StartAsync(int attempt)
    {
        _since = System.Diagnostics.Stopwatch.StartNew();
        RemoveFailure();
        IsReady = false;
        Mode = 0;
        _source.Visibility = Visibility.Collapsed;
        // Each attempt gets a web view of its own: one closed with an earlier window or attempt never comes back.
        if (_web is { } old)
        {
            _room.Children.Remove(old);
            try { old.Close(); } catch (Exception) { }
        }
        var web = new WebView2();
        AutomationProperties.SetAutomationId(web, "artifact.page");
        _web = web;
        _room.Children.Add(web);
        PlaceWeb();
        _page.Visibility = Visibility.Visible;
        ShowLoading(true);
        Notify();
        _ = WatchStartAsync(attempt);
        try
        {
            await Look.EnsureAsync(web);
        }
        catch (Exception e)
        {
            var d = _life.Threw(attempt, e.GetType().Name);
            if (d.Step == PagePreviewStep.Fail) ArtifactActions.Log($"page preview failed: {e.GetType().Name}");
            Act(d);
            return;
        }
        ArtifactActions.Log($"page preview: web view ready ({_since.ElapsedMilliseconds} ms)");
        var ready = _life.WebReady(attempt, ReferenceEquals(_web, web) && web.CoreWebView2 != null);
        if (ready.Step != PagePreviewStep.Navigate) { Act(ready); return; }
        _ = WatchAsync(attempt);   // the draw limit runs from here: WebView2's own start has StartLimit
        try
        {
            var core = web.CoreWebView2!;
            core.Settings.IsZoomControlEnabled = false;   // [WIN-PAGE-ZOOM] one level, the bar's: no second Ctrl+wheel zoom
            Look.Guard(web, _preview);
            core.NavigationCompleted += (_, e) => Act(_life.NavigationDone(attempt, e.IsSuccess, e.WebErrorStatus.ToString()));
            core.ProcessFailed += (_, e) =>
            {
                ArtifactActions.Log($"page preview: its process went ({e.ProcessFailedKind})");
                Act(_life.ProcessGone(attempt));
            };
            core.Navigate(new Uri(_preview).AbsoluteUri);
        }
        catch (Exception e)
        {
            var d = _life.Threw(attempt, e.GetType().Name);
            if (d.Step == PagePreviewStep.Fail) ArtifactActions.Log($"page preview failed: {e.GetType().Name}");
            Act(d);
        }
    }

    private async Task WatchStartAsync(int attempt)
    {
        await Task.Delay(PagePreviewLife.StartLimit);
        var d = _life.StartTimedOut(attempt);
        if (d.Step == PagePreviewStep.Fail) ArtifactActions.Log("page preview: its web view didn't start in time");
        Act(d);
    }

    private async Task WatchAsync(int attempt)
    {
        await Task.Delay(PagePreviewLife.DrawLimit);
        var d = _life.TimedOut(attempt);
        if (d.Step == PagePreviewStep.Fail) ArtifactActions.Log("page preview: didn't draw in time");
        Act(d);
    }

    private void ShowLoading(bool on)
    {
        _loading.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        _spinner.IsActive = on;
        AutomationProperties.SetName(_loading, on ? PagePreviewWords.Loading(Title) : "");
    }

    /// The failure state over the Preview (the text viewer's: Couldn't Open This File, why, Try Again), with Show
    /// Source: the page's text, which the file still has.
    private void ShowFailure(string reason)
    {
        ShowLoading(false);
        IsReady = false;
        _page.Visibility = Visibility.Collapsed;
        RemoveFailure();
        _failure = Look.State("\uE9CE", ArtifactPageWords.CouldntOpenFile, reason,
            (ArtifactPageWords.TryAgain, () => Act(_life.Retry())),
            (PagePreviewWords.ShowSource, () => { SetMode(1); Notify(); }));
        AutomationProperties.SetAutomationId(_failure, "artifact.page.failure");
        AutomationProperties.SetName(_failure, $"{ArtifactPageWords.CouldntOpenFile} {reason}");
        AutomationProperties.SetLiveSetting(_failure, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Assertive);
        _failure.Visibility = Mode == 0 ? Visibility.Visible : Visibility.Collapsed;
        Children.Add(_failure);
        Notify();
    }

    private void RemoveFailure()
    {
        if (_failure != null) Children.Remove(_failure);
        _failure = null;
    }

    public override void SetMode(int mode)
    {
        Mode = mode;
        var failed = _life.Phase == PagePreviewPhase.Failed;
        _page.Visibility = mode == 0 && !failed ? Visibility.Visible : Visibility.Collapsed;
        if (_failure != null) _failure.Visibility = mode == 0 ? Visibility.Visible : Visibility.Collapsed;
        _loading.Visibility = mode == 0 && _life.Phase == PagePreviewPhase.Loading ? Visibility.Visible : Visibility.Collapsed;
        _source.Visibility = mode == 1 ? Visibility.Visible : Visibility.Collapsed;
        if (mode == 1 && !_sourceRead) _ = ReadSourceAsync();
    }

    /// A page opened from a file (a file window) comes without its text: Source reads it from the same copy.
    private async Task ReadSourceAsync()
    {
        _sourceRead = true;
        try
        {
            var data = await File.ReadAllBytesAsync(_preview);
            _sourceText.Text = System.Text.Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, ArtifactFiles.TextLimit));
        }
        catch (Exception e)
        {
            ArtifactActions.Log($"page source failed: {e.GetType().Name}");
            _sourceText.Text = ArtifactFiles.FailureText(e, image: false);
        }
    }
}

/// A PDF's pages drawn one under another (Windows.Data.Pdf; the Mac's Quick Look), zoomable.
internal sealed class PdfPagesView : Grid
{
    private readonly StackPanel _pages = new() { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(16) };

    public PdfPagesView(string file)
    {
        Background = Look.Brush("SolidBackgroundFillColorSecondaryBrush");
        var scroller = new ScrollViewer
        {
            Content = _pages, ZoomMode = ZoomMode.Enabled, MinZoomFactor = 0.5f, MaxZoomFactor = 5,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Auto,
        };
        AutomationProperties.SetAutomationId(scroller, "artifact.pdf");
        Children.Add(scroller);
        var ring = new ProgressRing { IsActive = true, Width = 28, Height = 28 };
        Children.Add(ring);
        var started = false;
        Loaded += async (_, _) =>
        {
            if (started) return;
            started = true;
            try
            {
                using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var ras = fs.AsRandomAccessStream();
                var document = await PdfDocument.LoadFromStreamAsync(ras);
                for (uint i = 0; i < document.PageCount; i++)
                {
                    using var page = document.GetPage(i);
                    using var stream = new InMemoryRandomAccessStream();
                    var width = (uint)Math.Clamp(page.Size.Width * 2, 600, 1800);
                    await page.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = width });
                    var image = new BitmapImage();
                    await image.SetSourceAsync(stream);
                    var picture = new Image { Source = image, Width = page.Size.Width * 1.33, Stretch = Stretch.Uniform };
                    AutomationProperties.SetName(picture, $"Page {i + 1} of {document.PageCount}");
                    _pages.Children.Add(new Border
                    {
                        Child = picture, Background = new SolidColorBrush(Microsoft.UI.Colors.White),
                        BorderBrush = Look.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
                    });
                }
            }
            catch (Exception e)
            {
                ArtifactActions.Log($"pdf failed: {e.GetType().Name}");
                Children.Add(Look.State("\uE9CE", ArtifactPageWords.CouldntOpenFile, "This PDF couldn’t be read."));
            }
            ring.IsActive = false;
            ring.Visibility = Visibility.Collapsed;
        };
    }
}
