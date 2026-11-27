using Hermes.Core.Settings;
using HermesHQ.Features.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Foundation;
using Windows.UI;

namespace HermesHQ.Shell;

/// [working-ring] The line that travels round a working bot's or chat's row (Mac `rowArc` / `WorkingArc`): a 1.25 px
/// outline in the row's corner, the accent in Light and the label colour in Dark (`WorkingArc.paint`), with two bright
/// spikes and their tails lapping it every `WorkingRing.LapSeconds`. When the system asks for less motion
/// (UISettings.AnimationsEnabled off, read only) it stands still at its start. Decoration only: it takes no clicks and
/// is not in the accessibility tree, so the row's own name ("…, Working") is what a screen reader hears. The caller
/// gates it (`WorkingRing.ShowsBotRing` / `ShowsChatRing` with the switch). This is a working indicator, not the Mac's
/// exact gradient travel along the outline.
internal static class WorkingRingView
{
    public const double Line = 1.25;

    /// The row with the ring over it when `on`; the row itself when not.
    public static UIElement Wrap(UIElement row, bool on, Thickness outset = default, double corner = 4)
    {
        if (!on) return row;
        var host = new Grid();
        host.Children.Add(row);
        host.Children.Add(Ring(outset, corner));
        return host;
    }

    public static Border Ring(Thickness outset, double corner)
    {
        var c1 = Accent();
        var clear = Color.FromArgb(0, c1.R, c1.G, c1.B);
        var tail = Color.FromArgb((byte)(c1.A * 0.45), c1.R, c1.G, c1.B);
        var spin = new RotateTransform { CenterX = 0.5, CenterY = 0.5 };
        var brush = new LinearGradientBrush
        {
            StartPoint = new Point(0, 0), EndPoint = new Point(1, 1), MappingMode = BrushMappingMode.RelativeToBoundingBox,
            RelativeTransform = spin,
        };
        // `WorkingArc.paint`'s stops: clear, a bright spike, its 45 % tail, clear; twice over.
        (Color, double)[] stops =
        [
            (clear, 0), (clear, 0.15), (c1, 0.20), (tail, 0.25), (clear, 0.35), (clear, 0.40), (clear, 0.55), (c1, 0.60),
            (tail, 0.65), (clear, 0.75), (clear, 0.80), (clear, 0.95), (c1, 1),
        ];
        foreach (var (color, offset) in stops) brush.GradientStops.Add(new GradientStop { Color = color, Offset = offset });
        var ring = new Border
        {
            BorderBrush = brush, BorderThickness = new Thickness(Line), CornerRadius = new CornerRadius(corner),
            Margin = new Thickness(-outset.Left, -outset.Top, -outset.Right, -outset.Bottom),
            IsHitTestVisible = false, Tag = "working-ring",
        };
        AutomationProperties.SetAccessibilityView(ring, AccessibilityView.Raw);
        Storyboard? lap = null;
        ring.Loaded += (_, _) =>
        {
            if (lap != null || !WorkingRing.Travels(AnimationsEnabled())) return;   // reduced motion: still at its start
            var turn = new DoubleAnimation
            {
                From = 0, To = 360, Duration = new Duration(TimeSpan.FromSeconds(WorkingRing.LapSeconds)),
                RepeatBehavior = RepeatBehavior.Forever, EnableDependentAnimation = true,
            };
            Storyboard.SetTarget(turn, spin);
            Storyboard.SetTargetProperty(turn, nameof(RotateTransform.Angle));
            lap = new Storyboard();
            lap.Children.Add(turn);
            lap.Begin();
        };
        ring.Unloaded += (_, _) =>
        {
            lap?.Stop();
            lap = null;
        };
        return ring;
    }

    /// Whether the system lets things move now. Read only: the app never changes the setting.
    private static bool AnimationsEnabled()
    {
        try { return new Windows.UI.ViewManagement.UISettings().AnimationsEnabled; }
        catch (Exception) { return true; }
    }

    /// The accent in Light, the label colour in Dark (`:root.dark .arc-border`).
    private static Color Accent()
    {
        var key = ThemeService.Dark ? "TextFillColorPrimaryBrush" : "AccentFillColorDefaultBrush";
        return Application.Current.Resources.TryGetValue(key, out var value) && value is SolidColorBrush b ? b.Color : Color.FromArgb(255, 0, 0x53, 0xFD);
    }
}
