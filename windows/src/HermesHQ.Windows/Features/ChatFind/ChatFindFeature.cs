using Hermes.Core.Model;
using Hermes.Core.Transcripts;
using HermesHQ.Controls;
using HermesHQ.Services;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using DispatcherQueuePriority = Microsoft.UI.Dispatching.DispatcherQueuePriority;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace HermesHQ.Features.ChatFind;

/// Find in a chat (App/Chat/Find/ChatFindController.swift at 93f984bb1; KeyCommands.swift Find… / Find Next / Find
/// Previous). Ctrl+F opens the bar over the top of the transcript, its field focused; it searches as typed (after a
/// short pause), counts the matches ("2 of 5", "No Results"), steps through them with ↑ (older) and ↓ (newer),
/// wrapping, and highlights them in the messages — every match yellow, the current one orange — bringing the current
/// one a third of the way down the transcript. Enter is Next; Esc or Done closes it and forgets the words.
///
/// Keys: Ctrl+F (the Mac's ⌘F); Find Next Ctrl+G (⌘G) and F3; Find Previous Ctrl+Shift+G (⇧⌘G) and Shift+F3. The Mac's
/// keys keep the muscle memory a Mac user brings; F3 / Shift+F3 are what Windows apps (Edge, Notepad, Explorer) use.
/// They are the chat page's own accelerators, so Ctrl+F on other pages (Tasks, Kanban, Artifacts…) still finds there.
public static class ChatFindFeature
{
    public static void Register()
    {
        ChatExtensions.OnOpen.Add(ctx => Install(ctx));
        MessageView.Drawn += view => ChatFindBar.ForView(view)?.Paint(view);
    }

    private static void Install(ChatContext ctx)
    {
        var bar = new ChatFindBar(ctx);
        InstallKeys(ctx.Page, bar);
        ctx.ComposerKeys.Add(e =>
        {
            if (e.Key != VirtualKey.Escape || !bar.IsOpen) return false;
            bar.Close();
            return true;
        });
    }

    /// Find's keys on a page that shows a transcript (a bot chat's, or a group room's: Pages/GroupRoomPage.cs).
    internal static void InstallKeys(UIElement page, ChatFindBar bar)
    {
        Accelerator(page, VirtualKey.F, VirtualKeyModifiers.Control, bar.Open);
        Accelerator(page, VirtualKey.G, VirtualKeyModifiers.Control, () => bar.Step(forward: true));
        Accelerator(page, VirtualKey.F3, VirtualKeyModifiers.None, () => bar.Step(forward: true));
        Accelerator(page, VirtualKey.G, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => bar.Step(forward: false));
        Accelerator(page, VirtualKey.F3, VirtualKeyModifiers.Shift, () => bar.Step(forward: false));
        // Esc's ladder: an open Find closes before a running reply is stopped (KeyRules.swift EscapeAction.decide), from
        // the message box (its own key handling runs first) and from anywhere else in the chat.
        var escape = new KeyboardAccelerator { Key = VirtualKey.Escape };
        escape.Invoked += (_, e) => { if (bar.IsOpen) { e.Handled = true; bar.Close(); } };
        page.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        page.KeyboardAccelerators.Add(escape);
    }

    private static void Accelerator(UIElement page, VirtualKey key, VirtualKeyModifiers mods, Action run)
    {
        var a = new KeyboardAccelerator { Key = key, Modifiers = mods };
        a.Invoked += (_, e) => { e.Handled = true; run(); };
        page.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        page.KeyboardAccelerators.Add(a);
    }
}

/// [WIN-52] What Find searches and draws over: a bot chat's transcript (ChatContext) or a group room's
/// (Pages/GroupRoomPage.cs, whose ⋯ Find in Chat and Ctrl+F open the same bar: the Mac's room is its chat screen).
public interface IChatFindHost
{
    /// The transcript control: the bar shares its grid cell, and its top padding makes room under the bar.
    Control Transcript { get; }
    IReadOnlyList<ChatMessage> Messages { get; }
    bool HasOlder { get; }
    Task LoadOlderAsync();
    /// Where the keyboard goes once Find closes. `rest` takes the keyboard without typing or acting on a key: the Mac's
    /// `close` only resigns the field, leaving nothing focused (so Space, the arrows and Enter do nothing, and a letter
    /// reaches the box through type-to-chat).
    void KeyboardAfterClose(Control rest);
    /// The drawn message is one of this transcript's.
    bool Owns(MessageView view);
    /// Brings the message's row into the realised rows (a virtualised list scrolls to it).
    void BringIntoView(string messageId);
    /// The scroller the transcript scrolls in (after layout).
    ScrollViewer? Scroller { get; }
    event Action? Changed;
    event Action? Closed;
}

/// A bot chat's transcript as Find's host.
internal sealed class ChatContextFindHost(ChatContext ctx) : IChatFindHost
{
    public Control Transcript => ctx.Transcript;
    public IReadOnlyList<ChatMessage> Messages => ctx.Session.Messages;
    public bool HasOlder => ctx.Session.HasOlder;
    public Task LoadOlderAsync() => ctx.Session.LoadOlderAsync();
    /// The Mac's nothing-focused: the rest element; type-to-chat (MacTypeToChat) sends the next letter to the box.
    public void KeyboardAfterClose(Control rest)
    {
        if (!rest.Focus(FocusState.Programmatic)) AppLog.Note("chatfind", "the keyboard stayed put after Find closed");
    }
    public bool Owns(MessageView view) => view.Item?.Owner?.Session == ctx.Session;
    public void BringIntoView(string messageId)
    {
        var item = (ctx.Transcript.ItemsSource as IEnumerable<MessageItem>)?.FirstOrDefault(i => i.Id == messageId);
        if (item != null) ctx.Transcript.ScrollIntoView(item, ScrollIntoViewAlignment.Leading);
    }
    public ScrollViewer? Scroller => ChatFindBar.Descendants<ScrollViewer>(ctx.Transcript).FirstOrDefault();
    public event Action? Changed { add => ctx.Session.Changed += value; remove => ctx.Session.Changed -= value; }
    public event Action? Closed { add => ctx.Closed += value; remove => ctx.Closed -= value; }
}

/// The bar: the field, with the count, ↑ ↓ and Done beside it or on the next line. Search Earlier Messages below while earlier messages
/// aren't loaded. One per open chat (a chat switch opens a new page, so Find starts closed there, as the Mac's).
public sealed class ChatFindBar
{
    private readonly Border _root = new();
    /// What holds the keyboard after Find closes, in place of the Mac's nothing: no words, no action, no picture. A tab
    /// stop only while it has the keyboard, so Tab never lands on it.
    private readonly ContentControl _rest = new()
    {
        Width = 1, Height = 1, Opacity = 0, IsHitTestVisible = false, IsTabStop = false, UseSystemFocusVisuals = false,
        HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
    };
    private static readonly List<WeakReference<ChatFindBar>> Open_ = [];
    private static Brush? _match, _current;
    /// `systemYellow` at 55 % for every match, `systemOrange` for the current one (ChatFindHighlight).
    private static Brush MatchBrush => _match ??= new SolidColorBrush(Windows.UI.Color.FromArgb(0x8C, 0xFF, 0xCC, 0x00));
    private static Brush CurrentBrush => _current ??= new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0xFF, 0x95, 0x00));

    private readonly IChatFindHost _ctx;
    private readonly ChatFindModel _model = new();
    private readonly TextBox _field = new();
    private readonly TextBlock _count = new();
    private readonly ChatFindRows _rows;
    private readonly Button _previous = new(), _next = new(), _done = new(), _earlier = new();
    private readonly DispatcherQueueTimer _typing, _changed;
    private Thickness _transcriptPadding;
    private bool _loadingOlder;
    private string _announced = "";

    public bool IsOpen => _model.IsActive;
    /// What the walk reads: the bar's count and how many matches it found.
    public string CountText => _model.CountText;
    public int MatchCount => _model.Matches.Count;
    /// The walk's query, typed as the field takes it.
    public void AutomationFind(string query) { Open(); _field.Text = query; Research(keepCurrent: false); }

    public ChatFindBar(ChatContext ctx) : this(new ChatContextFindHost(ctx)) { }

    public ChatFindBar(IChatFindHost ctx)
    {
        _ctx = ctx;
        // A short pause while typing, so a long chat isn't searched on every key; a little longer for new messages.
        _typing = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();
        _typing.Interval = TimeSpan.FromMilliseconds(120);
        _typing.IsRepeating = false;
        _typing.Tick += (_, _) => Research(keepCurrent: false);
        _changed = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();
        _changed.Interval = TimeSpan.FromMilliseconds(300);
        _changed.IsRepeating = false;
        _changed.Tick += (_, _) => Research(keepCurrent: true);
        // Out of Narrator's tree (the Mac's nothing-focused says nothing), and out of the tab order once it lets go.
        AutomationProperties.SetAccessibilityView(_rest, AccessibilityView.Raw);
        _rest.Name = RestName;
        _rest.LostFocus += (_, _) => _rest.IsTabStop = false;
        AutomationProperties.SetAutomationId(_root, "chatfind.bar");
        AutomationProperties.SetName(_root, "Find");
        _root.Visibility = Visibility.Collapsed;
        _root.VerticalAlignment = VerticalAlignment.Top;
        _root.HorizontalAlignment = HorizontalAlignment.Stretch;
        _root.MaxWidth = 900;
        _root.Margin = new Thickness(16, 6, 16, 0);
        // Including the one-DIP stroke: the Mac's 14 / 8 horizontal and 4 vertical content insets.
        _root.Padding = new Thickness(13, 3, 7, 3);
        _root.MinHeight = ChatFindLayout.MinimumHeight;
        _root.CornerRadius = new CornerRadius(20);
        _root.Background = Res("SolidBackgroundFillColorBaseBrush");
        _root.BorderBrush = Res("CardStrokeColorDefaultBrush");
        _root.BorderThickness = new Thickness(1);

        _field.PlaceholderText = ChatFindWords.Placeholder;
        _field.IsSpellCheckEnabled = false;
        _field.IsTextPredictionEnabled = false;
        _field.BorderThickness = new Thickness(0);
        _field.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _field.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(_field, "chatfind.field");
        AutomationProperties.SetName(_field, ChatFindWords.Placeholder);
        _field.TextChanged += (_, _) => { _typing.Stop(); _typing.Start(); };
        _field.KeyDown += OnFieldKey;

        _count.FontSize = 12;
        _count.VerticalAlignment = VerticalAlignment.Center;
        _count.Foreground = Res("TextFillColorSecondaryBrush");
        _count.Margin = new Thickness(0, 0, ChatFindLayout.AfterCount, 0);
        _count.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetAutomationId(_count, "chatfind.count");
        AutomationProperties.SetLiveSetting(_count, AutomationLiveSetting.Polite);

        Arrow(_previous, "\uE70E", ChatFindWords.Previous, "chatfind.previous", () => Step(forward: false));
        Arrow(_next, "\uE70D", ChatFindWords.Next, "chatfind.next", () => Step(forward: true));
        _done.Content = ChatFindWords.Done;
        _done.MinWidth = 0;
        _done.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        _done.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _done.BorderThickness = new Thickness(0);
        _done.Padding = new Thickness(6, 4, 6, 4);
        AutomationProperties.SetAutomationId(_done, "chatfind.done");
        AutomationProperties.SetName(_done, ChatFindWords.Done);
        _done.Click += (_, _) => Close();

        _earlier.Content = ChatFindWords.Earlier;
        _earlier.FontSize = 12;
        _earlier.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        _earlier.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _earlier.BorderThickness = new Thickness(0);
        _earlier.Padding = new Thickness(4, 4, 4, 6);
        _earlier.Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(_earlier, "chatfind.earlier");
        AutomationProperties.SetName(_earlier, ChatFindWords.Earlier);
        _earlier.Click += (_, _) => SearchEarlier();

        _rows = new ChatFindRows(_field, _count, _previous, _next, _done);
        _root.Child = new StackPanel { Spacing = 2, Children = { _rows, _earlier } };
        _root.SizeChanged += (_, e) =>
        {
            if (!IsOpen || e.NewSize.Height <= 0) return;
            _root.CornerRadius = new CornerRadius(e.NewSize.Height <= ChatFindLayout.MinimumHeight + 4 ? e.NewSize.Height / 2 : 24);
            UpdateInset(e.NewSize.Height);
        };

        // Over the top of the transcript (the Mac's: under the status line); the transcript's own grid cell.
        // The transcript's parent may not be known until it is loaded, so try again then; say so if it never is.
        RoutedEventHandler? onTranscriptLoaded = null;
        if (!Attach())
        {
            onTranscriptLoaded = (_, _) =>
            {
                if (Attach() && onTranscriptLoaded != null) ctx.Transcript.Loaded -= onTranscriptLoaded;
                else AppLog.Note("chatfind", $"no place for the bar: the transcript's parent is {ctx.Transcript.Parent?.GetType().Name ?? "none"}");
            };
            ctx.Transcript.Loaded += onTranscriptLoaded;
        }
        ctx.Changed += OnSessionChanged;
        ctx.Closed += () =>
        {
            if (onTranscriptLoaded != null) ctx.Transcript.Loaded -= onTranscriptLoaded;
            ctx.Changed -= OnSessionChanged;
            _typing.Stop();
            _changed.Stop();
            lock (Open_) Open_.RemoveAll(w => !w.TryGetTarget(out var b) || b == this);
        };
        lock (Open_) Open_.Add(new WeakReference<ChatFindBar>(this));
        Update();
    }

    /// Puts the bar in the transcript's own grid cell, once. False while the transcript has no panel to share.
    private bool Attach()
    {
        if (_root.Parent != null || VisualTreeHelper.GetParent(_root) != null) return true;
        if ((_ctx.Transcript.Parent ?? VisualTreeHelper.GetParent(_ctx.Transcript)) is not Panel host) return false;
        Grid.SetRow(_root, Grid.GetRow(_ctx.Transcript));
        Grid.SetRow(_rest, Grid.GetRow(_ctx.Transcript));
        host.Children.Add(_rest);
        host.Children.Add(_root);
        return true;
    }

    private static Brush Res(string key) => ThemeBrushes.Get(key);

    private static void Arrow(Button b, string glyph, string name, string id, Action run)
    {
        b.Content = new FontIcon { Glyph = glyph, FontSize = 14 };
        b.Width = ChatFindLayout.Arrow;
        b.MinWidth = 0;
        b.MinHeight = 40;
        b.Padding = new Thickness(0);
        b.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        b.BorderThickness = new Thickness(0);
        AutomationProperties.SetAutomationId(b, id);
        AutomationProperties.SetName(b, name);
        ToolTipService.SetToolTip(b, name);
        b.Click += (_, _) => run();
    }

    /// Used by the text-size fixture to open the installed bar of this transcript, never another chat's.
    internal static ChatFindBar? ForTranscript(Control transcript)
    {
        lock (Open_)
            foreach (var w in Open_)
                if (w.TryGetTarget(out var bar) && ReferenceEquals(bar._ctx.Transcript, transcript)) return bar;
        return null;
    }

    /// The bar a drawn message belongs to (its transcript's).
    internal static ChatFindBar? ForView(MessageView view)
    {
        lock (Open_)
            foreach (var w in Open_)
                if (w.TryGetTarget(out var bar) && bar.IsOpen && bar._ctx.Owns(view)) return bar;
        return null;
    }

    // MARK: Opening and closing

    public void Open()
    {
        if (!_model.IsActive)
        {
            _transcriptPadding = _ctx.Transcript.Padding;
            _model.Open();
            AppLog.Note("chatui", "find opened");
            _root.Visibility = Visibility.Visible;
            UpdateInset(_root.ActualHeight);
        }
        _field.Focus(FocusState.Keyboard);
        _field.SelectAll();
        if (_field.Text.Length > 0) Research(keepCurrent: true);
        Update();
    }

    private void UpdateInset(double drawnHeight)
    {
        var top = ChatFindLayout.TranscriptTop(_transcriptPadding.Top, IsOpen, drawnHeight);
        _ctx.Transcript.Padding = new Thickness(_transcriptPadding.Left, top, _transcriptPadding.Right, _transcriptPadding.Bottom);
    }

    public void Close()
    {
        if (!_model.IsActive) return;
        _typing.Stop();
        _changed.Stop();
        ParkKeyboard();
        _model.Close();
        AppLog.Note("chatui", "find closed");
        _field.Text = "";
        _typing.Stop();
        _root.Visibility = Visibility.Collapsed;
        _ctx.Transcript.Padding = _transcriptPadding;
        _announced = "";
        Update();
        PaintAll();
    }

    /// The keyboard off the field before the bar goes (a collapsed field's keyboard would go to the next stop, the box).
    private void ParkKeyboard()
    {
        // Esc in the message box (Find open) leaves the box its keyboard, as the Mac's close does.
        if (_root.XamlRoot is not { } root || !Within(FocusManager.GetFocusedElement(root) as DependencyObject, _root)) return;
        _rest.IsTabStop = true;   // Focus refuses a control that isn't a tab stop
        _ctx.KeyboardAfterClose(_rest);
        // A host that gave the keyboard elsewhere (a room's box), or a Focus that failed, leaves no invisible tab stop.
        if (!HoldsKeyboard(_rest)) _rest.IsTabStop = false;
    }

    /// The name the walk finds the rest element by (it isn't in the UIA tree, so it has no AutomationId).
    internal const string RestName = "chatfind.rest";

    private static bool HoldsKeyboard(Control c) =>
        c.XamlRoot is { } root && ReferenceEquals(FocusManager.GetFocusedElement(root), c);

    /// [walk] How many Find rest elements under `root` are tab stops without holding the keyboard (must be 0: Tab
    /// would land on an invisible element Narrator can't see).
    internal static int StrayRests(DependencyObject root) =>
        Descendants<ContentControl>(root).Count(c => c.Name == RestName && c.IsTabStop && !HoldsKeyboard(c));

    private static bool Within(DependencyObject? element, DependencyObject ancestor)
    {
        for (var at = element; at != null; at = VisualTreeHelper.GetParent(at))
            if (ReferenceEquals(at, ancestor)) return true;
        return false;
    }

    /// [walk] How many of Find's highlights (every match's, the current one's) are drawn under `root`.
    internal static int Highlights(DependencyObject root) =>
        Descendants<FrameworkElement>(root).Sum(e => (e switch
        {
            TextBlock tb => tb.TextHighlighters,
            RichTextBlock rich => rich.TextHighlighters,
            _ => null,
        })?.Count(h => h.Background == MatchBrush || h.Background == CurrentBrush) ?? 0);

    private void OnFieldKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter) { e.Handled = true; Step(forward: true); }   // Return reads Search: the next match
        else if (e.Key == VirtualKey.Escape) { e.Handled = true; Close(); }
    }

    // MARK: Searching

    /// The transcript changed while finding: the matches follow (the current one stays when it is still there).
    private void OnSessionChanged() => _root.DispatcherQueue.TryEnqueue(() =>
    {
        if (_loadingOlder && !_ctx.HasOlder) _loadingOlder = false;
        if (!_model.IsActive || Hermes.Core.Transcripts.ChatFind.Normalized(_model.Query).Length == 0) { if (_model.IsActive) Update(); return; }
        _changed.Stop();
        _changed.Start();
    });

    private void Research(bool keepCurrent)
    {
        if (!_model.IsActive) return;
        var reveal = _model.Search(_field.Text, _ctx.Messages, keepCurrent, _ctx.HasOlder);
        // Never the query itself: just how many turned up.
        AppLog.Note("chatui", $"find: {_model.Matches.Count} match(es)");
        Update();
        PaintAll();
        if (reveal) Reveal();
    }

    /// Search Earlier Messages: Find searches what is loaded, so this pages the next older stretch in; the matches
    /// follow when it arrives.
    private async void SearchEarlier()
    {
        if (!_ctx.HasOlder || _loadingOlder) return;
        _loadingOlder = true;
        Update();
        try { await _ctx.LoadOlderAsync(); }
        catch (Exception x) { AppLog.Note("chatui", $"find: earlier failed {x.GetType().Name}"); }
        finally { _loadingOlder = false; Update(); Research(keepCurrent: true); }
    }

    /// Find Next / Find Previous, the bar's ↓ and ↑: nothing to step to while closed or nothing is found.
    public void Step(bool forward)
    {
        if (!_model.CanStep) return;
        _model.Step(forward);
        Update();
        PaintAll();
        Reveal();
    }

    private void Update()
    {
        var text = _model.CountText;
        _rows.SetCount(text);
        _previous.IsEnabled = _next.IsEnabled = _model.Matches.Count > 0;
        if (text.Length > 0 && text != _announced && _model.IsActive)
        {
            _announced = text;
            if (FrameworkElementAutomationPeer.FromElement(_count) is { } peer)
                peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }
        var earlier = _model.IsActive && _ctx.HasOlder && Hermes.Core.Transcripts.ChatFind.Normalized(_model.Query).Length > 0;
        _earlier.Visibility = earlier ? Visibility.Visible : Visibility.Collapsed;
        _earlier.Content = _loadingOlder ? ChatFindWords.EarlierLoading : ChatFindWords.Earlier;
        _earlier.IsEnabled = !_loadingOlder;
    }

    // MARK: Highlights

    private void PaintAll()
    {
        foreach (var view in Descendants<MessageView>(_ctx.Transcript)) Paint(view);
    }

    /// Every occurrence in the message's drawn words yellow, the current one orange; nothing once Find closes.
    internal void Paint(MessageView view)
    {
        var highlight = view.Item is { } item ? _model.Highlight(item.Id) : null;
        var k = 0;
        foreach (var (block, ranges) in Occurrences(view, highlight?.Query))
        {
            var highlighters = block is TextBlock tb ? tb.TextHighlighters : ((RichTextBlock)block).TextHighlighters;
            for (var i = highlighters.Count - 1; i >= 0; i--)
                if (highlighters[i].Background == MatchBrush || highlighters[i].Background == CurrentBrush) highlighters.RemoveAt(i);
            if (highlight == null || ranges.Count == 0) continue;
            var others = new TextHighlighter { Background = MatchBrush };
            var current = new TextHighlighter { Background = CurrentBrush };
            foreach (var r in ranges)
            {
                (k == highlight.Current ? current : others).Ranges.Add(new TextRange { StartIndex = r.Start, Length = r.Length });
                k++;
            }
            if (others.Ranges.Count > 0) highlighters.Add(others);
            if (current.Ranges.Count > 0) highlighters.Add(current);
        }
    }

    /// The message's searched text elements in reading order, each with the query's occurrences in it (UTF-16 offsets
    /// into the element's plain text). The reply's time after its last words and link chips are not searched words.
    private static IEnumerable<(FrameworkElement Block, IReadOnlyList<ChatFindRange> Ranges)> Occurrences(MessageView view, string? query)
    {
        foreach (var root in view.FindableText)
        {
            IEnumerable<FrameworkElement> blocks = root is TextBlock or RichTextBlock ? [root] : TextBlocks(root);
            foreach (var block in blocks)
            {
                var text = block is TextBlock tb ? PlainText(tb) : PlainText((RichTextBlock)block);
                yield return (block, query == null ? [] : Hermes.Core.Transcripts.ChatFind.Ranges(query, text));
            }
        }
    }

    private static IEnumerable<FrameworkElement> TextBlocks(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is Features.Transcript.LinkChipView or Features.Transcript.PageCardView) continue;
            if (child is RichTextBlock rich) { yield return rich; continue; }
            if (child is TextBlock { FontSize: > 11 } tb) { yield return tb; continue; }
            foreach (var deeper in TextBlocks(child)) yield return deeper;
        }
    }

    private static string PlainText(TextBlock tb) =>
        tb.Inlines.Count == 0 ? tb.Text ?? "" : string.Concat(tb.Inlines.Select(InlineText));

    /// A RichTextBlock's text as TextHighlighter counts it: its paragraphs' words, one separator character between
    /// paragraphs (see ParagraphBreak).
    private static string PlainText(RichTextBlock rich) =>
        string.Join(ParagraphBreak, rich.Blocks.OfType<Paragraph>().Select(p => string.Concat(p.Inlines.Select(InlineText))));

    /// What one paragraph boundary counts as in a RichTextBlock's TextRange offsets. Unverified on a PC (nothing renders
    /// WinUI on the Mac): the first Windows run confirms the second paragraph's highlight lands on its word.
    internal const string ParagraphBreak = "\r";

    private static string InlineText(Inline inline) => inline switch
    {
        // The reply's time after its last words (MarkdownRenderer.Render's trailing run) is not a searched word.
        Run run when run.Text.StartsWith('\u2002') => new string('\uFFFC', run.Text.Length),
        Run run => run.Text,
        LineBreak => "\n",
        Span span => string.Concat(span.Inlines.Select(InlineText)),
        _ => "",
    };

    // MARK: Scrolling to the current match

    /// Brings the current match into view: its message first, then the occurrence a third of the way down the room
    /// under the bar.
    private void Reveal()
    {
        if (_model.CurrentMatch is not { } match) return;
        var list = _ctx.Transcript;
        _ctx.BringIntoView(match.MessageId);
        _root.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            list.UpdateLayout();
            var scroller = _ctx.Scroller;
            var view = Descendants<MessageView>(list).FirstOrDefault(v => v.Item?.Id == match.MessageId);
            if (scroller == null || view == null) return;
            Paint(view);
            var y = CurrentOccurrenceTop(view, scroller) ?? view.TransformToVisual(scroller).TransformPoint(default).Y;
            var room = Math.Max(1, scroller.ViewportHeight - _root.ActualHeight);
            var target = scroller.VerticalOffset + y - _root.ActualHeight - room / 3;
            scroller.ChangeView(null, Math.Clamp(target, 0, scroller.ScrollableHeight), null, disableAnimation: true);
        });
    }

    /// The current occurrence's top in the scroller's coordinates, from the text's own character position.
    private double? CurrentOccurrenceTop(MessageView view, ScrollViewer scroller)
    {
        if (view.Item is not { } item || _model.Highlight(item.Id) is not { Current: { } current } h) return null;
        var k = 0;
        foreach (var (block, ranges) in Occurrences(view, h.Query))
        {
            if (current >= k + ranges.Count) { k += ranges.Count; continue; }
            var top = block.TransformToVisual(scroller).TransformPoint(default).Y;
            if (block is RichTextBlock rich && Pointer(rich, ranges[current - k].Start) is { } at)
                return top + at.GetCharacterRect(LogicalDirection.Forward).Top;
            return top;
        }
        return null;
    }

    /// The TextPointer at a plain-text offset (PlainText's), walking the paragraphs' runs.
    private static TextPointer? Pointer(RichTextBlock rich, int offset)
    {
        var at = 0;
        foreach (var p in rich.Blocks.OfType<Paragraph>())
        {
            foreach (var run in Runs(p.Inlines))
            {
                var length = run is Run r ? r.Text.Length : 1;
                if (offset < at + length)
                    return run is Run ? run.ContentStart.GetPositionAtOffset(offset - at, LogicalDirection.Forward) : run.ContentStart;
                at += length;
            }
            at += ParagraphBreak.Length;
        }
        return null;
    }

    private static IEnumerable<Inline> Runs(InlineCollection inlines)
    {
        foreach (var i in inlines)
        {
            if (i is Span s) { foreach (var deeper in Runs(s.Inlines)) yield return deeper; }
            else if (i is Run or LineBreak) yield return i;
        }
    }

    internal static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T hit) yield return hit;
            foreach (var deeper in Descendants<T>(child)) yield return deeper;
        }
    }
}
