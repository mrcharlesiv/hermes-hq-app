using Hermes.Core.Composer;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using VirtualKey = Windows.System.VirtualKey;
using Windows.UI;

namespace HermesHQ.Features.Composer;

/// [WIN-MODEL-THINKING-STEPS] The Models foot's lit thinking bar (MacModelPicker.swift MacThinkingSteps at 93f984bb1):
/// a 16 pt track lit in the accent up to a 24 pt knob, a dot at each level (bright on the lit part, dim past it), calm.
/// A click on any step jumps there and a drag follows; ← and → step one level. `LevelMoved` fires on each level crossed
/// (the Mac's .valueChanged: the words beside the title follow), `EffortChosen` once it settles — a let-go, Enter, or
/// a pause after the last key (the Mac's .primaryActionTriggered). The rules are Hermes.Core's ThinkingSteps.
/// Screen readers get a Slider with UIA RangeValue (0…stops-1) and Value ("High, Thinks hard", the Mac's value).
internal sealed partial class ThinkingStepsBar : UserControl
{
    private readonly ThinkingStepsTrack track = new();
    private readonly Canvas canvas = new();
    private readonly Rectangle trackLine = new() { Height = ThinkingSteps.TrackHeight, RadiusX = ThinkingSteps.TrackHeight / 2, RadiusY = ThinkingSteps.TrackHeight / 2 };
    private readonly Rectangle litLine = new() { Height = ThinkingSteps.TrackHeight, RadiusX = ThinkingSteps.TrackHeight / 2, RadiusY = ThinkingSteps.TrackHeight / 2 };
    private readonly Canvas dots = new();
    private readonly Ellipse knob = new() { Width = ThinkingSteps.KnobSide, Height = ThinkingSteps.KnobSide, StrokeThickness = 3 };
    private readonly Border ring = new() { BorderThickness = new Thickness(2), CornerRadius = new CornerRadius(ThinkingSteps.Height / 2), Visibility = Visibility.Collapsed };
    private readonly DispatcherQueueTimer settle;
    private bool hovering;
    private double dragFraction;
    private string accessibleValue = "";

    /// A level was crossed (moving, not yet chosen).
    public event Action? LevelMoved;
    /// The bar settled on this level.
    public event Action<string?>? EffortChosen;

    public ThinkingStepsBar()
    {
        Height = ThinkingSteps.Height;
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        foreach (var part in new UIElement[] { trackLine, litLine, dots, knob })
        {
            part.IsHitTestVisible = false;
            canvas.Children.Add(part);
        }
        knob.RenderTransformOrigin = new global::Windows.Foundation.Point(0.5, 0.5);
        knob.RenderTransform = new ScaleTransform();
        var root = new Grid { Background = new SolidColorBrush(Colors.Transparent) };   // hit-testable end to end
        root.Children.Add(canvas);
        ring.IsHitTestVisible = false;
        ring.Margin = new Thickness(-2, 0, -2, 0);
        root.Children.Add(ring);
        Content = root;
        AutomationProperties.SetAutomationId(this, ThinkingSteps.Id);
        AutomationProperties.SetName(this, ThinkingSteps.AccessibleName);
        settle = DispatcherQueue.GetForCurrentThread().CreateTimer();
        settle.Interval = ThinkingSteps.Settle;
        settle.IsRepeating = false;
        settle.Tick += (_, _) => Commit();

        SizeChanged += (_, _) => Draw();
        ActualThemeChanged += (_, _) => Draw();                 // recolor on a theme change
        Unloaded += (_, _) => settle.Stop();
        IsEnabledChanged += (_, _) =>
        {
            track.Enabled = IsEnabled;
            Opacity = IsEnabled ? 1 : ThinkingSteps.DisabledOpacity;
            if (!IsEnabled) hovering = false;
            Draw();
        };
        GotFocus += (_, _) => ring.Visibility = FocusState == FocusState.Keyboard ? Visibility.Visible : Visibility.Collapsed;
        LostFocus += (_, _) => ring.Visibility = Visibility.Collapsed;
        PointerEntered += (_, _) => { hovering = IsEnabled; Draw(); };
        PointerExited += (_, _) => { hovering = false; Draw(); };
        PointerPressed += (_, e) =>
        {
            var x = e.GetCurrentPoint(this).Position.X;
            dragFraction = ThinkingSteps.Fraction(x, ActualWidth);
            if (!IsEnabled || track.Stops.Count < 2) return;
            Focus(FocusState.Pointer);
            CapturePointer(e.Pointer);
            if (track.Press(dragFraction)) Moved();
            Draw();
            e.Handled = true;
        };
        PointerMoved += (_, e) =>
        {
            if (!track.Dragging) return;
            dragFraction = ThinkingSteps.Fraction(e.GetCurrentPoint(this).Position.X, ActualWidth);
            if (track.Move(dragFraction)) Moved();
            Draw();
            e.Handled = true;
        };
        PointerReleased += (_, e) =>
        {
            if (!track.Dragging) return;
            var level = track.Release();
            ReleasePointerCapture(e.Pointer);
            Draw();
            EffortChosen?.Invoke(level);
            e.Handled = true;
        };
        // Capture taken away mid-drag (the dialog closing, another window): the Mac's cancelTracking — nothing sent.
        PointerCaptureLost += (_, _) =>
        {
            if (!track.Dragging) return;
            track.Cancel();
            Draw();
        };
        KeyDown += (_, e) =>
        {
            switch (e.Key)
            {
                case VirtualKey.Left: Step(-1); e.Handled = true; break;
                case VirtualKey.Right: Step(1); e.Handled = true; break;
                // Enter sets the level now instead of waiting for the keys' pause.
                case VirtualKey.Enter when track.Stops.Count > 1: Commit(); e.Handled = true; break;
            }
        };
    }

    public IReadOnlyList<string> Stops => track.Stops;
    public int Stop => track.Stop;
    public string? Level => track.Level;
    internal string AccessibleValue => accessibleValue;

    /// The stops and the lit one, from the foot's state (`bar.stops = efforts; bar.setStop(...)`).
    public void Set(IReadOnlyList<string> stops, int stop)
    {
        track.Set(stops, stop);
        Draw();
    }

    /// The foot's words for the level the bar is on; what a screen reader hears.
    public void SetAccessibleValue(string value)
    {
        var old = accessibleValue;
        accessibleValue = value;
        if (old != value && FrameworkElementAutomationPeer.FromElement(this) is AutomationPeer peer)
            peer.RaisePropertyChangedEvent(ValuePatternIdentifiers.ValueProperty, old, value);
    }

    /// One level, set once the keys pause, so a run of presses sends one change (also UIA's SetValue).
    internal void Step(int by)
    {
        var before = track.Stop;
        if (!track.Step(by)) return;
        Draw();
        Moved(before);
        settle.Stop();
        settle.Start();
    }

    internal void StepTo(int index) => Step(index - track.Stop);

    private void Commit()
    {
        settle.Stop();
        EffortChosen?.Invoke(track.Level);
    }

    private void Moved(int? before = null)
    {
        LevelMoved?.Invoke();
        if (before is { } b && FrameworkElementAutomationPeer.FromElement(this) is AutomationPeer peer)
            peer.RaisePropertyChangedEvent(RangeValuePatternIdentifiers.ValueProperty, (double)b, (double)track.Stop);
    }

    private static Color Tinted(string key, double alpha)
    {
        var color = Ui.Res<SolidColorBrush>(key).Color;
        return Color.FromArgb((byte)Math.Round(color.A * alpha), color.R, color.G, color.B);
    }

    private void Draw()
    {
        var w = ActualWidth;
        var count = track.Stops.Count;
        if (count < 2 || w <= 0 || ThinkingSteps.To(w) <= ThinkingSteps.From) return;
        var y = ThinkingSteps.Height / 2;
        var fraction = track.Dragging ? dragFraction : ThinkingSteps.Position(track.Stop, count);
        double X(double f) => ThinkingSteps.From + (ThinkingSteps.To(w) - ThinkingSteps.From) * f;
        // The track's round ends sit where the knob would at each end (from - knob/2 … to + knob/2).
        var left = ThinkingSteps.From - ThinkingSteps.KnobSide / 2;
        trackLine.Width = Math.Max(0, ThinkingSteps.To(w) + ThinkingSteps.KnobSide / 2 - left);
        Canvas.SetLeft(trackLine, left);
        Canvas.SetTop(trackLine, y - ThinkingSteps.TrackHeight / 2);
        trackLine.Fill = new SolidColorBrush(Tinted("TextFillColorPrimaryBrush", 0.13));
        var knobX = X(fraction);
        litLine.Width = Math.Max(ThinkingSteps.TrackHeight, knobX + ThinkingSteps.TrackHeight / 2 - left);
        Canvas.SetLeft(litLine, left);
        Canvas.SetTop(litLine, y - ThinkingSteps.TrackHeight / 2);
        litLine.Fill = Ui.Res<Brush>("AccentFillColorDefaultBrush");
        dots.Children.Clear();
        var on = new SolidColorBrush(Tinted("TextOnAccentFillColorPrimaryBrush", 0.9));
        var off = new SolidColorBrush(Tinted("TextFillColorPrimaryBrush", 0.32));
        for (var i = 0; i < count; i++)
        {
            if (i == track.Stop && !track.Dragging) continue;   // under the knob
            var p = ThinkingSteps.Position(i, count);
            var dot = new Ellipse { Width = ThinkingSteps.DotSide, Height = ThinkingSteps.DotSide, Fill = p <= fraction + 0.001 ? on : off };
            Canvas.SetLeft(dot, X(p) - ThinkingSteps.DotSide / 2);
            Canvas.SetTop(dot, y - ThinkingSteps.DotSide / 2);
            dots.Children.Add(dot);
        }
        knob.Fill = Ui.Res<Brush>("AccentFillColorDefaultBrush");
        knob.Stroke = Ui.Res<Brush>("TextOnAccentFillColorPrimaryBrush");
        Canvas.SetLeft(knob, knobX - ThinkingSteps.KnobSide / 2);
        Canvas.SetTop(knob, y - ThinkingSteps.KnobSide / 2);
        var grow = track.Dragging ? 1.12 : hovering ? 1.06 : 1;
        if (knob.RenderTransform is ScaleTransform scale) { scale.ScaleX = grow; scale.ScaleY = grow; }
        ring.BorderBrush = Ui.Res<Brush>("AccentFillColorDefaultBrush");
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    /// A Slider to UIA: RangeValue steps a level at a time (as VoiceOver's increment/decrement), Value is the words.
    private sealed partial class Peer(ThinkingStepsBar bar) : FrameworkElementAutomationPeer(bar), IRangeValueProvider, IValueProvider
    {
        protected override object GetPatternCore(PatternInterface patternInterface) =>
            patternInterface is PatternInterface.RangeValue or PatternInterface.Value ? this : base.GetPatternCore(patternInterface);

        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Slider;
        protected override string GetClassNameCore() => nameof(ThinkingStepsBar);
        protected override string GetNameCore() => ThinkingSteps.AccessibleName;
        protected override bool IsKeyboardFocusableCore() => bar.IsEnabled && bar.IsTabStop;

        public double Value => bar.Stop;
        public double Minimum => 0;
        public double Maximum => Math.Max(0, bar.Stops.Count - 1);
        public double SmallChange => 1;
        public double LargeChange => 1;
        bool IRangeValueProvider.IsReadOnly => !bar.IsEnabled || bar.Stops.Count < 2;

        public void SetValue(double value)
        {
            if (!bar.IsEnabled) throw new ElementNotEnabledException();
            bar.StepTo((int)Math.Round(Math.Clamp(value, Minimum, Maximum)));
        }

        string IValueProvider.Value => bar.AccessibleValue;
        bool IValueProvider.IsReadOnly => true;
        void IValueProvider.SetValue(string value) => throw new InvalidOperationException("The Thinking value is read-only; set its level.");
    }
}
