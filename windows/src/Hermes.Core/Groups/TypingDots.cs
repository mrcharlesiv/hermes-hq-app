namespace Hermes.Core.Groups;

/// [WIN-57] The typing dots' wave (App/Chat/Cells/ChatCells.swift ChatWaitingCell `animate`): each of the three dots
/// brightens in turn, 0.2 s apart, every 1.2 s, on one shared clock so a row drawn again doesn't restart the wave. The
/// keyframes are the Mac's `CAKeyframeAnimation(keyPath: "opacity")`: values 0.3, 1, 0.3, 0.3 at 0, 0.25, 0.5, 1 of the
/// period, ease-in-ease-out into and out of the peak, linear at rest. Under Reduce Motion (Windows: UISettings
/// AnimationsEnabled off) the dots stand still at 60 % (`dot.alpha = 0.6`): typing dots aren't decoration, so they ask
/// the motion setting, not power saving (App/Kit/Accessibility/HQMotion.swift).
public static class TypingDots
{
    public const int Count = 3;
    public const double Period = 1.2;
    public const double Stagger = 0.2;
    public const double StillOpacity = 0.6;
    /// Each dot's side and the gap between them (ChatCells.swift: 6 pt dots, corner radius 3).
    public const double Side = 6;

    public enum Curve { EaseInEaseOut, Linear }

    /// (key time as a fraction of the period, opacity).
    public static readonly IReadOnlyList<(double KeyTime, double Opacity)> Keys = [(0, 0.3), (0.25, 1), (0.5, 0.3), (1, 0.3)];
    /// The curve into each key after the first (`timingFunctions`).
    public static readonly IReadOnlyList<Curve> Curves = [Curve.EaseInEaseOut, Curve.EaseInEaseOut, Curve.Linear];
    /// `CAMediaTimingFunction(name: .easeInEaseOut)`'s control points; a WinUI KeySpline takes the same two.
    public static readonly (double X1, double Y1, double X2, double Y2) EaseInEaseOut = (0.42, 0, 0.58, 1);

    /// Whether the dots move: only while the system lets things animate.
    public static bool Animates(bool animationsEnabled) => animationsEnabled;

    /// How far into its wave dot `index` is at `nowSeconds` on the shared clock (`fmod(now - n * 0.2 + period, period)`).
    public static double Offset(int index, double nowSeconds)
    {
        var x = (nowSeconds - index * Stagger + Period) % Period;
        if (x < 0) x += Period;
        return Math.Abs(x - Period) < 1e-9 ? 0 : x;
    }

    /// Dot `index`'s opacity at `nowSeconds`: the wave, or 60 % when animations are off.
    public static double Opacity(int index, double nowSeconds, bool animationsEnabled)
    {
        if (!Animates(animationsEnabled)) return StillOpacity;
        var f = Offset(index, nowSeconds) / Period;
        for (var k = 1; k < Keys.Count; k++)
        {
            var (t0, v0) = Keys[k - 1];
            var (t1, v1) = Keys[k];
            if (f > t1 && k < Keys.Count - 1) continue;
            var u = t1 > t0 ? Math.Clamp((f - t0) / (t1 - t0), 0, 1) : 1;
            var eased = Curves[k - 1] == Curve.EaseInEaseOut ? Ease(u) : u;
            return v0 + (v1 - v0) * eased;
        }
        return Keys[^1].Opacity;
    }

    /// The ease-in-ease-out cubic Bézier's progress at time fraction `x` (0…1).
    public static double Ease(double x)
    {
        x = Math.Clamp(x, 0, 1);
        var (x1, y1, x2, y2) = EaseInEaseOut;
        static double Bezier(double t, double a, double b) => 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t;
        double lo = 0, hi = 1, t = x;
        for (var i = 0; i < 60; i++)
        {
            t = (lo + hi) / 2;
            if (Bezier(t, x1, x2) < x) lo = t; else hi = t;
        }
        return Bezier(t, y1, y2);
    }
}
