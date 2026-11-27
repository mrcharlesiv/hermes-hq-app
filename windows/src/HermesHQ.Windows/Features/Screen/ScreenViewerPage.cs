using Hermes.Core.Screen;
using HermesHQ.Features.Capabilities;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace HermesHQ.Features.Screen;

/// [WIN-SCREEN-PAGE] A bot's Screen (App/Screen/ScreenViewerController.swift's view at 93f984bb1, docs/spec/3x-screen.md
/// §5): the title ("Otto’s Screen") with the screen's label under it, Zoom Out / Zoom In and Close at its end; the notes
/// under it; the stage (the picture) with the state panel over it; the latest-screenshots page in its place when the
/// gateway has no live screen; the control bar under it, and the short note (the pill) above the bar. The state machine
/// is Hermes.Core's ScreenViewerController; this page is its IScreenViewerHost and draws each ScreenViewerState.
internal sealed class ScreenViewerPage : Grid, IScreenViewerHost
{
    public ScreenViewerController Viewer { get; private set; } = null!;
    public ScreenStageView Stage { get; private set; } = null!;
    public ScreenViewerState? Last { get; private set; }
    public LatestScreenshotsView? Fallback { get; private set; }
    /// The page goes away (the window closes it).
    public Action? OnDismiss { get; set; }
    /// The control-only setup sheet over the Screen (the app opens it; the page calls `gone` when it closes).
    public Func<ScreenViewerPage, Task>? ControlSetup { get; set; }

    private readonly TextBlock _title = new() { FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock _subtitle = new() { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Button _zoomIn = Glyph("\uE8A3", "Zoom In", "screen.zoomIn");
    private readonly Button _zoomOut = Glyph("\uE71F", "Zoom Out", "screen.zoomOut");
    private readonly Button _close = Glyph("\uE711", "Close", "screen.close");
    private readonly ScreenNotesView _notes = new();
    private readonly Grid _content = new();
    private readonly PanelView _panel = new();
    private readonly ScreenControlBar _bar = new();
    private readonly Border _pill = new()
    {
        CornerRadius = new CornerRadius(18), Padding = new Thickness(14, 8, 14, 8), HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(16, 0, 16, 10), Visibility = Visibility.Collapsed, IsHitTestVisible = false,
    };
    private readonly TextBlock _pillText = new() { FontSize = 13, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxLines = 3 };
    /// The key field that types on the bot's screen (`keyField`): its KeyDown and CharacterReceived go to the viewer's
    /// ScreenKeyInput (ScreenKeyFeed); it never keeps what is typed.
    private readonly TextBox _keyField = new() { Width = 1, Height = 1, Opacity = 0, IsTabStop = false, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
    private readonly ScreenKeepAwake _awake = new();
    private bool _keyFocused;

    public ScreenViewerPage()
    {
        AutomationProperties.SetAutomationId(this, "screen.page");
        Background = HermesHQ.Features.Settings.ThemeService.BrushFor("HQPageBrush");
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // title
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // notes
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });   // stage, panel, screenshots
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // bar

        var head = new Grid { Padding = new Thickness(16, 8, 8, 8), ColumnSpacing = 4 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(_title);
        titles.Children.Add(_subtitle);
        _subtitle.Foreground = Kit.Secondary;
        AutomationProperties.SetHeadingLevel(_title, AutomationHeadingLevel.Level1);
        AutomationProperties.SetAutomationId(_title, "screen.title");
        AutomationProperties.SetAutomationId(_subtitle, "screen.subtitle");
        head.Children.Add(titles);
        // [mac] Zoom Out and Zoom In beside the title (the order of `rightBarButtonItems`), then Close at the end.
        Grid.SetColumn(_zoomOut, 1); head.Children.Add(_zoomOut);
        Grid.SetColumn(_zoomIn, 2); head.Children.Add(_zoomIn);
        Grid.SetColumn(_close, 3); head.Children.Add(_close);
        Children.Add(head);

        Grid.SetRow(_notes, 1);
        Children.Add(_notes);
        Grid.SetRow(_content, 2);
        Children.Add(_content);
        Grid.SetRow(_bar, 3);
        Children.Add(_bar);

        _pill.Background = Kit.Brush("AcrylicInAppFillColorDefaultBrush");
        _pill.Child = _pillText;
        Grid.SetRow(_pill, 2);
        Children.Add(_pill);
        Children.Add(_keyField);
        _keyField.GotFocus += (_, _) => KeyFocus(true);
        _keyField.LostFocus += (_, _) => KeyFocus(false);
        _keyField.PreviewKeyDown += KeyFieldKeyDown;
        _keyField.CharacterReceived += KeyFieldCharacter;
        // [WIN-SCREEN-INPUT-WIRE] Nothing typed stays in the field: the characters went to the bot as they came.
        _keyField.BeforeTextChanging += (_, e) => { if (e.NewText.Length > 0) e.Cancel = true; };
        SizeChanged += (_, e) => { if (Viewer != null) Viewer.UpdateCompactTyping(new ScreenSize(_content.ActualWidth, _content.ActualHeight), Viewer.Stage.TappedRow); _notes.MaxHeight = Math.Max(60, e.NewSize.Height * 0.3); };
    }

    private static Button Glyph(string glyph, string name, string id)
    {
        var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 14 }, MinWidth = 40, MinHeight = 40, Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0) };
        AutomationProperties.SetName(button, name);
        AutomationProperties.SetAutomationId(button, id);
        ToolTipService.SetToolTip(button, name);
        return button;
    }

    /// Wires the page to its viewer (made by ScreenViewerController.Open with this page as its host) and loads it.
    public void Attach(ScreenViewerController viewer)
    {
        Viewer = viewer;
        Stage = new ScreenStageView(viewer, viewer.BotName);
        Stage.ViewChanged = (view, committed) => viewer.StageViewChanged(view, committed);
        _content.Children.Add(Stage);
        _content.Children.Add(_panel);
        _panel.OnPrimary = viewer.PanelPrimary;
        _panel.OnSecondary = viewer.PanelSecondary;
        _notes.OnDismissError = viewer.DismissError;
        _notes.OnEnableControl = viewer.EnableControl;
        _bar.OnTake = viewer.Take;
        _bar.OnGive = viewer.Give;
        _bar.OnForce = viewer.Force;
        _bar.OnFit = viewer.Fit;
        _bar.OnKeyboard = viewer.Keyboard;
        _bar.OnKey = viewer.Key;
        _bar.OnModifier = viewer.Modifier;
        _bar.OnPaste = () => _ = viewer.Paste();
        _zoomIn.Click += (_, _) => viewer.Zoom(ScreenZoomStep.ZoomIn);
        _zoomOut.Click += (_, _) => viewer.Zoom(ScreenZoomStep.ZoomOut);
        _close.Click += (_, _) => viewer.Close();
        // The picture: frames go straight to the bitmap (the controller keeps only the latest for its state).
        viewer.Load();
        var drawFrames = viewer.Session.OnFrame;
        viewer.Session.OnFrame = (image, width, height) =>
        {
            drawFrames?.Invoke(image, width, height);
            Stage.Show(image, width, height);
        };
    }

    // IScreenViewerHost

    public void Render(ScreenViewerState state)
    {
        Last = state;
        _title.Text = state.Title;
        _subtitle.Text = state.Subtitle ?? "";
        _subtitle.Visibility = state.Subtitle == null ? Visibility.Collapsed : Visibility.Visible;
        _zoomIn.Visibility = _zoomOut.Visibility = state.Zoomable ? Visibility.Visible : Visibility.Collapsed;
        Stage.Draw(state);
        _panel.Model = state.Panel;
        _notes.Set(state.Notes, Announce);
        _bar.Visibility = state.BarHidden ? Visibility.Collapsed : Visibility.Visible;
        _bar.Model = state.Bar;
        RenderFallback(state);
        if (state.Pill is { } pill)
        {
            _pillText.Text = pill.Text;
            AutomationProperties.SetAutomationId(_pill, pill.Id);
            _pill.Visibility = pill.Shown ? Visibility.Visible : Visibility.Collapsed;
        }
        else _pill.Visibility = Visibility.Collapsed;
    }

    private void RenderFallback(ScreenViewerState state)
    {
        if (state.Fallback is not { } model) return;
        if (Fallback == null)
        {
            if (Viewer.Session is null || Viewer is null) return;
            if (ScreenFeature.FeedGateway(Viewer) is not { } gateway) return;
            var feed = new ScreenshotFeed(gateway, Viewer.Profile, Viewer.BotName)
            {
                IsMine = e => Viewer.OwnsSession?.Invoke(e.SessionId ?? "") ?? false,
            };
            Fallback = new LatestScreenshotsView(feed, Announce) { LoadImage = ScreenFeature.LoadShot };
            Fallback.Card.OnSetup = () => Viewer.RequestSetupAsync(Fallback.Card.Requested, controlOnly: false);
            Fallback.Card.OnCheck = Viewer.CheckSetupAsync;
            if (Viewer.SetupRequestedBefore) Fallback.Card.ShowRequested();
            _content.Children.Add(Fallback);
        }
        Fallback.Managed = model.Managed;
        Fallback.Update(model.Reason, model.Blocker);
        Fallback.SetVisible(state.FallbackShown && model.Visible);
    }

    public bool KeyboardFocused => _keyFocused;
    public void RaiseKeyboard() => _keyField.Focus(FocusState.Programmatic);
    public void LowerKeyboard() { if (_keyFocused) Focus(FocusState.Programmatic); }

    private void KeyFocus(bool on)
    {
        if (on == _keyFocused) return;
        _keyFocused = on;
        // The key field's rules hear the focus first (a half surrogate pair is dropped); they tell the viewer.
        Viewer?.KeyInput.FocusChanged(on);
    }

    // [WIN-SCREEN-INPUT-WIRE] The key field's keys (ScreenKeyField): KeyDown (named keys and chords, handled so Tab and
    // the arrows stay here) and CharacterReceived (text). AltGr is the right Alt with Ctrl; a chord's punctuation is
    // the US layout's unshifted character (ScreenKeyFeed.Unshifted: no ToUnicodeEx).
    private static bool Down(VirtualKey key) =>
        Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private static ScreenKeyState KeysNow() => new(
        Shift: Down(VirtualKey.Shift), Ctrl: Down(VirtualKey.Control), Alt: Down(VirtualKey.Menu),
        Meta: Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows), RightAlt: Down(VirtualKey.RightMenu));

    private void KeyFieldKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (Viewer == null) return;
        if (ScreenKeyFeed.KeyDown(Viewer.KeyInput, (int)e.Key, KeysNow(), e.KeyStatus.WasKeyDown)) e.Handled = true;
    }

    private void KeyFieldCharacter(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        if (Viewer == null) return;
        ScreenKeyFeed.Character(Viewer.KeyInput, e.Character, KeysNow());
        e.Handled = true;
    }

    public void Announce(string text)
    {
        var peer = FrameworkElementAutomationPeer.FromElement(_title) ?? FrameworkElementAutomationPeer.CreatePeerForElement(_title);
        peer?.RaiseNotificationEvent(AutomationNotificationKind.Other, AutomationNotificationProcessing.ImportantMostRecent, text, "screen");
    }

    public void CopyText(string text) => SafeClipboard.TrySetText(text);

    public async Task<string?> ReadClipboard()
    {
        var view = SafeClipboard.TryGetContent();
        if (view == null || !view.Contains(StandardDataFormats.Text)) return null;
        try { return await view.GetTextAsync(); }
        catch (Exception) { return null; }
    }

    public void SetStageView(ScreenView view, bool animated) => Stage.SetView(view, animated);
    public void ZoomStage(double factor) => Stage.ZoomBy(factor);
    public void FitStage() => Stage.Fit();
    public void KeepAwake(bool on) => _awake.Set(on);
    public bool AwakeHeld => _awake.Held;

    public void PresentControlSetup(Action gone)
    {
        if (ControlSetup is not { } present) { gone(); return; }
        _ = Present();
        async Task Present()
        {
            try { await present(this); }
            finally { gone(); }
        }
    }

    public void Dismiss() => OnDismiss?.Invoke();

    /// [mac] The page takes the keyboard while nothing in it types: the window's = / - / 0, Ctrl+W and Escape find it.
    public void TakeKeys() => Focus(FocusState.Programmatic);

    /// The window's keys (`keyCommands`): the zoom keys unmodified, Escape and Ctrl+W. True when taken.
    public bool Key(VirtualKey key, bool ctrl, bool shift)
    {
        if (ctrl && key == VirtualKey.W) { if (Viewer.CanClose) Viewer.Close(); return true; }
        if (key == VirtualKey.Escape && Viewer.CanClose) { Viewer.Escape(); return true; }
        if (ctrl) return false;
        var input = key switch
        {
            (VirtualKey)187 => shift ? "+" : "=",   // VK_OEM_PLUS
            VirtualKey.Add => "+",
            (VirtualKey)189 or VirtualKey.Subtract => "-",   // VK_OEM_MINUS
            VirtualKey.Number0 or VirtualKey.NumberPad0 => "0",
            _ => null,
        };
        return input != null && Viewer.ZoomKey(input);
    }

    /// The centred words and buttons of the states that are not a picture (ScreenStatePanel): over the dimmed picture
    /// (attaching) clear with white words, otherwise on the page. A reading width of 440 at most, centred.
    private sealed class PanelView : Grid
    {
        public Action? OnPrimary, OnSecondary;
        private readonly StackPanel _stack = new() { MaxWidth = 440, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(28, 20, 28, 20), Spacing = 8 };
        private readonly ProgressRing _spinner = new() { Width = 32, Height = 32 };
        private readonly TextBlock _title = Centred(20, bold: true);
        private readonly TextBlock _body = Centred(14);
        private readonly TextBlock _footnote = Centred(12);
        private readonly Border _code = new() { CornerRadius = new CornerRadius(12), Padding = new Thickness(10, 12, 10, 12) };
        private readonly TextBlock _codeText = new() { FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 13, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        private readonly Button _primary = new() { MinHeight = 48, HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly Button _secondary = new() { MinHeight = 48, HorizontalAlignment = HorizontalAlignment.Stretch };
        private ScreenPanelModel _model = new() { Hidden = true };

        public PanelView()
        {
            _code.Background = Kit.Brush("CardBackgroundFillColorDefaultBrush");
            _code.Child = _codeText;
            AutomationProperties.SetAutomationId(_codeText, "screen.command");
            AutomationProperties.SetHeadingLevel(_title, AutomationHeadingLevel.Level2);
            _primary.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            _primary.Click += (_, _) => OnPrimary?.Invoke();
            _secondary.Click += (_, _) => OnSecondary?.Invoke();
            foreach (var view in new UIElement[] { _spinner, _title, _body, _footnote, _code, _secondary, _primary }) _stack.Children.Add(view);
            _body.Margin = _footnote.Margin = new Thickness(0, 0, 0, 14);
            _code.Margin = new Thickness(0, 0, 0, 10);
            Children.Add(new ScrollViewer { Content = _stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
            Visibility = Visibility.Collapsed;
        }

        private static TextBlock Centred(double size, bool bold = false) => new()
        {
            FontSize = size, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
            FontWeight = bold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
        };

        public ScreenPanelModel Model
        {
            get => _model;
            set { if (value != _model) { _model = value; Apply(); } }
        }

        private void Apply()
        {
            var m = _model;
            Visibility = m.Hidden ? Visibility.Collapsed : Visibility.Visible;
            _spinner.IsActive = !m.Hidden && m.Spinner;
            if (m.Hidden) return;
            Background = m.OverPicture ? new SolidColorBrush(Colors.Transparent) : HermesHQ.Features.Settings.ThemeService.BrushFor("HQPageBrush");   // #78
            IsHitTestVisible = !m.OverPicture;
            var text = m.OverPicture ? new SolidColorBrush(Colors.White) : Kit.Primary;
            var quiet = m.OverPicture ? new SolidColorBrush(Windows.UI.Color.FromArgb(0xD9, 0xFF, 0xFF, 0xFF)) : Kit.Secondary;
            _spinner.Visibility = m.Spinner ? Visibility.Visible : Visibility.Collapsed;
            if (m.OverPicture) _spinner.Foreground = new SolidColorBrush(Colors.White); else _spinner.ClearValue(Control.ForegroundProperty);
            _title.Text = m.Title ?? "";
            _title.Foreground = text;
            _title.Visibility = m.Title == null ? Visibility.Collapsed : Visibility.Visible;
            AutomationProperties.SetAutomationId(_title, m.Id + ".title");
            _body.Text = m.Body;
            _body.Foreground = m.Title == null ? quiet : Kit.Secondary;
            _body.Visibility = m.Body.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            AutomationProperties.SetAutomationId(_body, m.Id);
            _footnote.Text = m.Footnote ?? "";
            _footnote.Foreground = Kit.Secondary;
            _footnote.Visibility = m.Footnote == null ? Visibility.Collapsed : Visibility.Visible;
            AutomationProperties.SetAutomationId(_footnote, m.Id + ".footnote");
            _codeText.Text = m.Code ?? "";
            _code.Visibility = m.Code == null ? Visibility.Collapsed : Visibility.Visible;
            _primary.Visibility = m.Primary == null ? Visibility.Collapsed : Visibility.Visible;
            _primary.Content = m.Working
                ? new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { new ProgressRing { IsActive = true, Width = 16, Height = 16 }, new TextBlock { Text = m.Primary ?? "" } } }
                : m.Primary;
            AutomationProperties.SetName(_primary, m.Primary ?? "");
            _primary.IsEnabled = !m.Working;
            AutomationProperties.SetAutomationId(_primary, m.PrimaryId);
            _secondary.Visibility = m.Secondary == null ? Visibility.Collapsed : Visibility.Visible;
            _secondary.Content = m.Secondary;
            AutomationProperties.SetAutomationId(_secondary, m.SecondaryId);
        }
    }
}
