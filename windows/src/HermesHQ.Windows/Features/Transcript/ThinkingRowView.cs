using Hermes.Core.Chat;
using Hermes.Core.Groups;
using Hermes.Core.Transcripts;
using HermesHQ.Controls;
using HermesHQ.Features.Settings;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;

namespace HermesHQ.Features.Transcript;

/// [toolnow] The chat's thinking row (ChatCells.swift `ChatWaitingCell`): at the transcript's newest end while a turn
/// runs, the typing dots and "Ivy is thinking…", or the step that runs ("Ivy is running npm test…", Hermes.Core
/// ThinkingRow); from 10 s the timer beside the words, past a minute "Ivy is still working…" unless a step runs. Its
/// automation name is the words it shows, timer included (`turnStatusCopy`). Once the turn has steps a click shows
/// them (the inspector's Steps; the Mac's Steps sheet). [WIN-THINKING-STEP]
/// [WIN-THINKING-FACE] Drawn as the Mac draws it (Hermes.Core WaitingLayout): the bot's 24 px face, 6 px, a 40×24
/// capsule in the bot bubble's colour holding the three typing dots, 8 px, then the words in label-2 and the timer in
/// label-3; the words end in "…" before the timer, which always shows whole; the words shimmer (WaitingShimmer) unless
/// Windows asks for fewer animations. The face and the capsule are hidden from UI Automation, as the Mac's cell hides
/// its subviews; the row's name is unchanged. On a chat background the Mac sets one pill under the face, dots, words
/// and timer; Windows has no chat-background picture yet (`BackdropShows`), so the pill is placed but never shown.
/// [WIN-THINKING-TEXT-STYLE] The words and the timer are the Mac's `style.notice` (Hermes.Core ChatStyle): 12.705 in the
/// Desktop Look, 11.55 in the iOS look at UI Scale 100 %, regular, in the window's typeface (a skin's in the Desktop
/// Look); the timer in the same size with steady-width digits (`HQFont.monoDigitFace`), plain digits under a skin's
/// typeface as the Mac. The row lays out on the Mac's line (`style.notice.lineHeight`), which follows Windows' text size
/// as the Mac's follows Dynamic Type; WinUI grows the words by the text size itself. Like a UILabel, each line of words
/// is centred in that line box.
/// A room's typing row (the Mac's `WaitingLayout(plain: true)`, `chat.typing`) is reachable on Windows, but not here:
/// Pages/GroupRoomPage `ShowTyping` draws it on its own (28 px face, a padded capsule, 12 px words), not through
/// WaitingLayout or this font; it is left as it is.
internal sealed class ThinkingRowView
{
    /// The Mac's `Backdrop.chats.shows`: Windows has no chat-background picture setting yet.
    internal static bool BackdropShows => false;

    private readonly ChatContext _ctx;
    private readonly Button _root;
    private readonly Grid _line;
    private readonly Border _pill;
    private readonly BotHead _face;
    private readonly Border _capsule;
    private readonly Canvas _dots;
    private readonly TextBlock _words;
    private readonly TextBlock _timer;
    /// Off-tree twins that measure the words' and the timer's natural widths (`sizeThatFits`).
    private readonly TextBlock _measureWords = new();
    private readonly TextBlock _measureTimer = new();
    private readonly List<Storyboard> _waves = [];
    private Storyboard? _shimmer;
    private string _shimmerKey = "";
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _ticker;
    private readonly Windows.UI.ViewManagement.UISettings _settings = new();
    private readonly Action _openSteps;
    private WaitingRow? _row;
    private WaitingLayout? _layout;
    private bool _timerShown;
    /// When each turn was first seen waiting (TurnClock.start): the timer doesn't restart as the row comes and goes.
    private readonly Dictionary<string, DateTimeOffset> _since = [];
    private int _pending;
    private bool _closed;

    /// The notice font now (ChatStyle.Notice for the look, UI Scale and Windows' text size).
    private NoticeFont _notice = ChatStyle.Notice(false, 100, 1);
    /// The row's margins in the transcript column and its widest (the bubbles' column).
    private const double Side = 24, Widest = 852;

    /// The words the row shows now (null while it isn't drawn), for the automation run.
    public string? Shown => _row == null ? null : AutomationProperties.GetName(_root);

    private ThinkingRowView(ChatContext ctx, Action openSteps)
    {
        _ctx = ctx;
        _openSteps = openSteps;
        _dots = new Canvas { Width = WaitingLayout.CapsuleWidth, Height = WaitingLayout.CapsuleHeight };
        for (var d = 0; d < TypingDots.Count; d++)
            _dots.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse
            {
                Width = TypingDots.Side, Height = TypingDots.Side, Opacity = TypingDots.StillOpacity,
            });
        _capsule = new Border
        {
            Width = WaitingLayout.CapsuleWidth, Height = WaitingLayout.CapsuleHeight,
            CornerRadius = new CornerRadius(WaitingLayout.CapsuleHeight / 2), Child = _dots,
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false,
        };
        AutomationProperties.SetAccessibilityView(_capsule, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        _face = new BotHead
        {
            Width = WaitingLayout.FaceSide, Height = WaitingLayout.FaceSide, IsHitTestVisible = false,
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
        };
        AutomationProperties.SetAccessibilityView(_face, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        _pill = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false,
            Visibility = Visibility.Collapsed, Background = ThemeBrushes.Get("AcrylicInAppFillColorDefaultBrush"),
        };
        AutomationProperties.SetAccessibilityView(_pill, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        _words = new TextBlock
        {
            TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap,
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
        };
        // The timer always shows whole; a long step's words end in "…" before it (owner, 2026-10-28).
        _timer = new TextBlock
        {
            TextWrapping = TextWrapping.NoWrap, Opacity = 0,
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
        };
        _line = new Grid { HorizontalAlignment = HorizontalAlignment.Left };
        _line.Children.Add(_pill);
        _line.Children.Add(_face);
        _line.Children.Add(_capsule);
        _line.Children.Add(_words);
        _line.Children.Add(_timer);
        _root = new Button
        {
            Content = _line, Background = null, BorderThickness = new Thickness(0), Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Left, HorizontalContentAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(Side, 6, Side, 6), MaxWidth = Widest, Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_root, ThinkingRow.AutomationId);
        _root.Click += (_, _) => { if (_row?.OpensSteps == true) _openSteps(); };
        _ticker = ctx.Page.DispatcherQueue.CreateTimer();
        _ticker.Interval = TimeSpan.FromSeconds(1);
        _ticker.Tick += (_, _) => Tick();
        _settings.AnimationsEnabledChanged += OnAnimations;
        _settings.TextScaleFactorChanged += OnTextScale;
        ctx.TranscriptFooter.SizeChanged += OnWidth;
        ThemeService.Changed += OnTheme;
        Restyle();
        Paint();
    }

    /// The row on this chat's transcript, above the features' rows at its end (the approval card, the question note).
    public static ThinkingRowView Attach(ChatContext ctx, Action openSteps)
    {
        var view = new ThinkingRowView(ctx, openSteps);
        ctx.TranscriptFooter.Children.Insert(0, view._root);
        var session = ctx.Session;
        session.Changed += view.Queue;
        ChatDisplaySettings.Changed += view.Queue;
        ctx.WaitsOnUserChanged += view.Queue;
        ctx.Closed += () =>
        {
            view._closed = true;
            session.Changed -= view.Queue;
            ChatDisplaySettings.Changed -= view.Queue;
            ctx.WaitsOnUserChanged -= view.Queue;
            view._settings.AnimationsEnabledChanged -= view.OnAnimations;
            view._settings.TextScaleFactorChanged -= view.OnTextScale;
            ctx.TranscriptFooter.SizeChanged -= view.OnWidth;
            ThemeService.Changed -= view.OnTheme;
            view.StopShimmer();
            view._ticker.Stop();
            view.StopWaves();
        };
        view.Queue();
        return view;
    }

    private void OnAnimations(Windows.UI.ViewManagement.UISettings s, object o)
    {
        if (_closed || AppShutdown.Stopping) return;
        _ctx.Page.DispatcherQueue.TryEnqueue(() =>
        {
            if (_closed || AppShutdown.Stopping) return;
            StopWaves();
            if (_row != null) { StartWaves(); Tick(force: true); }
        });
    }

    private void OnWidth(object sender, SizeChangedEventArgs e)
    {
        if (_row != null && Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > 0.5) Tick(force: true);
    }

    private void OnTheme()
    {
        if (_closed || AppShutdown.Stopping) return;
        _ctx.Page.DispatcherQueue.TryEnqueue(() =>
        {
            if (_closed || AppShutdown.Stopping) return;
            Restyle();
            Paint();
            if (_row != null) Tick(force: true);
        });
    }

    /// Windows' text size changed: the Mac's line follows it (the words grow by WinUI's own text scaling).
    private void OnTextScale(Windows.UI.ViewManagement.UISettings s, object o)
    {
        if (_closed || AppShutdown.Stopping) return;
        _ctx.Page.DispatcherQueue.TryEnqueue(() =>
        {
            if (_closed || AppShutdown.Stopping) return;
            Restyle();
            if (_row != null) Tick(force: true);
        });
    }

    private double TextScale()
    {
        try { return _settings.TextScaleFactor; }
        catch (System.Runtime.InteropServices.COMException) { return 1; }
    }

    /// [WIN-THINKING-TEXT-STYLE] The words and the timer in the Mac's notice font (ChatStyle): its size and weight, the
    /// window's typeface (set on the off-tree measuring twins too, which inherit nothing), and the timer's steady digits.
    private void Restyle()
    {
        var state = ThemeService.State;
        _notice = ChatStyle.Notice(state.DesktopLook, state.UiScalePercent, TextScale());
        var family = ChatStyle.NoticeFamily(state.DesktopLook, state.Skin.SansFamily);
        var numerals = ChatStyle.TimerTabular(state.DesktopLook, state.Skin.SansFamily)
            ? Microsoft.UI.Xaml.FontNumeralAlignment.Tabular : Microsoft.UI.Xaml.FontNumeralAlignment.Normal;
        var weight = new Windows.UI.Text.FontWeight { Weight = (ushort)_notice.Weight };
        foreach (var block in new[] { _words, _timer, _measureWords, _measureTimer })
        {
            block.FontSize = _notice.FontSize;
            block.FontWeight = weight;
            if (block == _measureWords || block == _measureTimer)
            {
                if (family != null) block.FontFamily = new FontFamily(family);
                else block.ClearValue(TextBlock.FontFamilyProperty);
            }
        }
        foreach (var block in new[] { _timer, _measureTimer })
            Microsoft.UI.Xaml.Documents.Typography.SetNumeralAlignment(block, numerals);
        _shimmerKey = "";
    }

    /// The capsule in the bot bubble's colour, the dots and the words in label-2, the timer in label-3; on the pill the
    /// dots stand on it in the words' ink with no capsule of their own, and the words and timer take the primary label.
    private void Paint()
    {
        var pill = BackdropShows;
        _capsule.Background = pill ? null : ThemeBrushes.Get("HQBotBubbleBrush");
        var dot = ThemeBrushes.Get(pill ? "TextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush");
        foreach (var d in _dots.Children) ((Microsoft.UI.Xaml.Shapes.Ellipse)d).Fill = dot;
        _words.Foreground = ThemeBrushes.Get(pill ? "TextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush");
        _timer.Foreground = ThemeBrushes.Get(pill ? "TextFillColorPrimaryBrush" : "TextFillColorTertiaryBrush");
        _shimmerKey = "";
    }

    private void Queue()
    {
        if (Interlocked.Exchange(ref _pending, 1) == 1) return;
        _ctx.Page.DispatcherQueue.TryEnqueue(() =>
        {
            Interlocked.Exchange(ref _pending, 0);
            if (!_closed) Refresh();
        });
    }

    /// The bot's name the row speaks of (ChatViewModel.BotName).
    private string BotName => _ctx.Session.Profile is { Length: > 0 } p && p != "default" ? char.ToUpperInvariant(p[0]) + p[1..] : "Hermes";

    private void Refresh()
    {
        var session = _ctx.Session;
        // ChatViewController's isRunning: our turn or another process's, not while a send waits for the owner.
        var turn = ExternalSurfaces.Transcript(session.Busy, session.ExternalWorking, session.WaitingForOwner != null);
        var row = ThinkingRow.Build(new ThinkingRow.Input(session.Messages, turn.Running, BotName)
        {
            Style = ChatDisplaySettings.Style, WaitsOnUser = _ctx.WaitsOnUser, Roster = DeliveryRoster.Seats,
        });
        var was = _row;
        _row = row;
        if (row == null)
        {
            if (was == null) return;
            _root.Visibility = Visibility.Collapsed;
            _ticker.Stop();
            StopWaves();
            StopShimmer();
            AutomationProperties.SetName(_root, "");
            return;
        }
        if (!_since.ContainsKey(row.Turn)) _since[row.Turn] = DateTimeOffset.UtcNow;
        // [thinking] The chat's own bot leads the dots (its face, or its initial while the roster hasn't loaded it).
        var profile = _ctx.Session.Profile is { Length: > 0 } p ? p : "default";
        var bot = (AppState.Client?.Bots ?? []).FirstOrDefault(b => b.Name == profile);
        if (_face.Bot != bot) _face.Bot = bot;
        if (_face.DisplayName != BotName) _face.DisplayName = BotName;
        _root.IsTabStop = row.OpensSteps;
        ToolTipService.SetToolTip(_root, row.OpensSteps ? ThinkingRow.StepsTip : null);
        AutomationProperties.SetHelpText(_root, row.OpensSteps ? ThinkingRow.StepsHint : "");
        Tick(force: was == null);
        if (was == null)
        {
            var atEnd = Scroller() is not { } sv || sv.VerticalOffset >= sv.ScrollableHeight - 60;
            _root.Visibility = Visibility.Visible;
            // At the end the row comes into view with it (the transcript follows its end, ChatPage `stickToEnd`).
            if (atEnd) _ctx.Page.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
                () => { if (!_closed && !AppShutdown.Stopping) Scroller()?.ChangeView(null, Scroller()!.ScrollableHeight, null, true); });
            _ticker.Start();
            StartWaves();
            AppLog.Note("chat", "thinking row shown");
        }
    }

    /// The words and the timer as time passes; the automation name keeps in step with them. [WIN-THINKING-FACE] The
    /// words get the room the timer leaves (WaitingLayout.WordsWidth), the timer stands 5 px after them and fades in
    /// at 10 s, the pill follows them, and the words shimmer.
    private void Tick(bool force = false)
    {
        if (_row is not { } row) return;
        var seconds = Math.Max(0, (int)(DateTimeOffset.UtcNow - _since[row.Turn]).TotalSeconds);
        var text = ThinkingRow.Line(row.Label, row.LongLabel, seconds, row.Doing);
        var time = ThinkingRow.Elapsed(seconds);
        var changed = force || _words.Text != text || _timer.Text != time;
        if (_words.Text != text) _words.Text = text;
        if (_timer.Text != time) _timer.Text = time;
        var name = ThinkingRow.Words(row.Label, row.LongLabel, seconds, row.Doing);
        if (AutomationProperties.GetName(_root) != name) AutomationProperties.SetName(_root, name);
        if (changed) Place(time, force);
    }

    /// Where everything stands for the row's width (WaitingLayout.Make), the words trimmed to their room.
    private void Place(string time, bool force)
    {
        var available = _ctx.TranscriptFooter.ActualWidth;
        var width = Math.Min(Widest, available > 0 ? available - 2 * Side : Widest);
        _measureWords.Text = "0";
        _measureWords.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        // [WIN-THINKING-TEXT-STYLE] The row stands on the Mac's notice line; WinUI's own line for the words (Segoe's is
        // taller than San Francisco's) is centred in it, as a UILabel centres its line in its frame.
        var lineHeight = _notice.LineHeight;
        var natural = _measureWords.DesiredSize.Height;
        var zeroWidth = _measureWords.DesiredSize.Width;
        // The Mac's row starts at the side inset inside its own width; here the margin is outside it, so the lead is 0
        // and the trailing 16 px still stands.
        var layout = WaitingLayout.Make(width, lineHeight, gap: 0, lead: 0, bot: true, plain: false);
        _layout = layout;
        var inset = WaitingLayout.PillInset(BackdropShows);
        _line.Height = layout.Height;
        if (layout.Face is { } face) { _face.Visibility = Visibility.Visible; _face.Margin = new Thickness(face.X + inset, face.Y, 0, 0); }
        else _face.Visibility = Visibility.Collapsed;
        _capsule.Margin = new Thickness(layout.Capsule.X + inset, layout.Capsule.Y, 0, 0);
        var x = WaitingLayout.DotsStart(layout.Capsule.Width, inset);
        foreach (var dot in _dots.Children)
        {
            Canvas.SetLeft(dot, x);
            Canvas.SetTop(dot, WaitingLayout.DotTop(layout.Capsule.Height));
            x += WaitingLayout.DotSide + WaitingLayout.DotSpacing;
        }
        var room = WaitingLayout.Room(layout.Text.Width, inset);
        _measureTimer.Text = time;
        _measureTimer.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        var reserve = WaitingLayout.Reserve(time, _measureTimer.DesiredSize.Width);
        _measureWords.Text = _words.Text;
        _measureWords.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        var wordsWidth = WaitingLayout.WordsWidth(room, reserve, Math.Ceiling(_measureWords.DesiredSize.Width));
        var wordsX = layout.Text.X + inset;
        _words.Width = wordsWidth;
        var lineY = layout.Text.Y + (layout.Text.Height - natural) / 2;
        _words.Margin = new Thickness(wordsX, lineY, 0, 0);
        var timerX = WaitingLayout.TimerX(wordsX, wordsWidth);
        // The timer's line centred on the words' (`label.frame.midY - timerLabel.frame.height / 2`, rounded).
        var timerY = Math.Round(lineY + natural / 2 - _measureTimer.DesiredSize.Height / 2, MidpointRounding.AwayFromZero);
        _timer.Margin = new Thickness(timerX, timerY, 0, 0);
        var show = time.Length > 0;
        if (show != _timerShown || force)
        {
            var fade = show && !_timerShown && !force && _settings.AnimationsEnabled;
            _timerShown = show;
            if (fade) Fade(_timer);
            else _timer.Opacity = show ? 1 : 0;
        }
        var pill = WaitingLayout.Pill(layout.Face is { } f ? f.X + inset : null, layout.Capsule with { X = layout.Capsule.X + inset },
            wordsX + wordsWidth, _timerShown, timerX + Math.Ceiling(_measureTimer.DesiredSize.Width), lineHeight);
        _pill.Visibility = BackdropShows ? Visibility.Visible : Visibility.Collapsed;
        _pill.Margin = new Thickness(pill.X, pill.Y, 0, 0);
        _pill.Width = pill.Width;
        _pill.Height = pill.Height;
        _pill.CornerRadius = new CornerRadius(WaitingLayout.PillRadius(pill));
        _line.Width = Math.Max(timerX + _measureTimer.DesiredSize.Width, pill.X + pill.Width);
        Shimmer(wordsWidth, natural, WaitingShimmer.Band(zeroWidth));   // over the words' own line
    }

    /// The timer fades in over the Mac's `HQMotion.move` (0.3 s); only called while Windows lets things animate.
    private static void Fade(UIElement element)
    {
        var fade = new DoubleAnimation { From = 0, To = 1, Duration = new Duration(TimeSpan.FromSeconds(0.3)) };
        Storyboard.SetTarget(fade, element);
        Storyboard.SetTargetProperty(fade, "Opacity");
        var board = new Storyboard();
        board.Children.Add(fade);
        board.Completed += (_, _) => element.Opacity = 1;
        try { board.Begin(); }
        catch (System.Runtime.InteropServices.COMException) { element.Opacity = 1; }
    }

    /// [WIN-THINKING-FACE] The desktop's shimmer (Mac `Shimmer.set(true, on: label)`): the words' brush is a 17-stop
    /// gradient a band wide, leaning 15°, swept across them on the shared clock. Light: the band fades the words to a
    /// fifth of their alpha; dark: it lights them up with the primary label. Off (the plain brush) when Windows asks
    /// for fewer animations, the Mac's Reduce Motion.
    private void Shimmer(double width, double height, double band)
    {
        var dark = ThemeService.Dark;
        var key = $"{dark} {width} {height} {band} {BackdropShows}";
        if (!WaitingShimmer.Runs(_settings.AnimationsEnabled, width, height))
        {
            if (_shimmer != null || _words.Foreground is LinearGradientBrush) { StopShimmer(); Paint(); }
            return;
        }
        if (_shimmer != null && key == _shimmerKey) return;
        StopShimmer();
        _shimmerKey = key;
        var tokens = ThemeService.Tokens;
        var ink = BackdropShows ? tokens.Label : tokens.Label2;
        var plan = WaitingShimmer.Sweep(width, height, band);
        var brush = new LinearGradientBrush
        {
            MappingMode = BrushMappingMode.Absolute, StartPoint = new Windows.Foundation.Point(0, 0),
            EndPoint = new Windows.Foundation.Point(plan.Width, 0), SpreadMethod = GradientSpreadMethod.Pad,
        };
        for (var i = 0; i < plan.Locations.Count; i++)
        {
            var resting = WaitingShimmer.Resting[i];
            var colour = dark ? tokens.Label.Alpha(tokens.Label.A * WaitingShimmer.DarkGlow(resting)).Over(ink)
                : ink.Alpha(ink.A * WaitingShimmer.LightAlpha(resting));
            brush.GradientStops.Add(new GradientStop { Color = ThemeService.ToColor(colour), Offset = plan.Locations[i] });
        }
        var move = new TranslateTransform { X = plan.From };
        var group = new TransformGroup();
        group.Children.Add(new SkewTransform { AngleX = -15, CenterY = height / 2 });
        group.Children.Add(move);
        brush.Transform = group;
        var pass = WaitingShimmer.Pass(band);
        var sweep = new DoubleAnimation
        {
            From = plan.From, To = plan.To, Duration = new Duration(TimeSpan.FromSeconds(pass)), EnableDependentAnimation = true,
        };
        Storyboard.SetTarget(sweep, move);
        Storyboard.SetTargetProperty(sweep, "X");
        var lap = new Storyboard
        {
            Duration = new Duration(TimeSpan.FromSeconds(WaitingShimmer.Lap(band))), RepeatBehavior = RepeatBehavior.Forever,
        };
        lap.Children.Add(sweep);
        _words.Foreground = brush;
        try
        {
            lap.Begin();
            lap.Seek(TimeSpan.FromSeconds(WaitingShimmer.Offset(Environment.TickCount64 / 1000.0, band)));
            _shimmer = lap;
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            AppLog.Note("chat", "the thinking row's shimmer didn't start; the words stay still");
            _shimmerKey = "";
            Paint();
        }
    }

    private void StopShimmer()
    {
        _shimmer?.Stop();
        _shimmer = null;
    }

    private ScrollViewer? Scroller() => Find<ScrollViewer>(_ctx.Transcript);

    private static T? Find<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T found) return found;
            if (Find<T>(child) is { } deeper) return deeper;
        }
        return null;
    }

    private void StartWaves()
    {
        if (!TypingDots.Animates(_settings.AnimationsEnabled) || _waves.Count > 0) return;
        var clock = Environment.TickCount64 / 1000.0;   // the shared clock, as a room's typing rows
        for (var d = 0; d < _dots.Children.Count; d++)
        {
            try { _waves.Add(GroupRoomPage.Wave(_dots.Children[d], d, clock)); }
            catch (System.Runtime.InteropServices.COMException) { AppLog.Note("chat", "a thinking dot's wave didn't start; the dot stays still"); }
        }
    }

    private void StopWaves()
    {
        foreach (var wave in _waves) wave.Stop();
        _waves.Clear();
        foreach (var dot in _dots.Children) dot.Opacity = TypingDots.StillOpacity;
    }
}
