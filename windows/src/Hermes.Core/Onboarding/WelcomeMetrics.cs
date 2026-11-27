using Hermes.Core.Settings;

namespace Hermes.Core.Onboarding;

/// BlockLineHeight reserves a full pitch even for the first line. EndMargin gives back just that excess.
public readonly record struct WelcomeLine(double Pitch, double EndMargin);

/// First-run welcome only. Mac 1245: MacTypeSteps.swift:11–14 (geometry), ThemeFonts.swift:96–109,213–224
/// and ThemeState.swift:69–92 (fonts). At ordinary size the Mac base is 1.15 for type, not for layout.
public readonly record struct WelcomeMetrics(double Title, double Body, double Detail, double Symbol, double SymbolTrack, double ButtonMinHeight,
    double ButtonCorner, WelcomeLine TitleLine, WelcomeLine LeadLine, double HeadlineLine, double DetailLine)
{
    public const double Catalyst = 0.77;
    public const double SymbolGap = 14 * Catalyst, PointTextGap = 2 * Catalyst;

    public static WelcomeMetrics For(double textScale, bool desktop, int uiPercent = 100)
    {
        var s = double.IsFinite(textScale) && textScale > 0 ? textScale : 1;
        // Shipping HQFont.preferred: apply the look's Mac base and the retained percentage BEFORE rounding
        // the role to a half UIKit point. Windows applies its own accessibility text scaling to these fonts.
        var app = uiPercent / 100.0;
        var factor = app * (desktop ? 1.3 : 1.15);
        double Face(double standard, double desktopSize)
        {
            var points = Math.Round((desktop ? desktopSize : standard) * factor * 2, MidpointRounding.AwayFromZero) / 2;
            return (desktop ? Math.Max(15, points) : points) * Catalyst;
        }
        // WelcomeView.swift:7,36–48; OnboardingKit.swift:431–451; MacForm.swift:97,728–734.
        // Only the symbol track and the button label's minimum height are ScaledMetric in Swift. WinUI
        // scales the actual type. Away from ordinary text let the shaper choose its native line height (0).
        // Detached 1245 font measurements at ordinary size. Swift adds line spacing *between* lines, not after
        // the last one. The first normal title line is 46 pt, the next 47; the lead is 24 then 26. In the desktop
        // face those pairs are 34/34 and 24/27. No wrap count (or fixed block height) belongs in the layout.
        bool ordinary = s == 1 && uiPercent == 100;
        WelcomeLine Lines(double first, double pitch) => ordinary ? new(pitch * Catalyst, (first - pitch) * Catalyst) : default;
        var body = Face(17, 15);
        // The plain push radius follows the rounded body face's line height (23 UIKit points at ordinary size).
        var bodyLine = 23 * (body / (19.5 * Catalyst)) * s;
        return new(Face(34, 22), body, Face(15, 13.5), Face(20, 16),
            Math.Min(30 * s, 52) * Catalyst, (34 * s + 2 * 4) * Catalyst,
            (desktop ? 7.5 : Math.Ceiling((Math.Ceiling(bodyLine) + 8) / 2)) * Catalyst,
            desktop ? Lines(34, 34) : Lines(46, 47), Lines(24, desktop ? 27 : 26),
            ordinary ? 24 * Catalyst : 0, ordinary ? 21 * Catalyst : 0);
    }

    /// MacForm.swift:736–752,790–805. Paint the native buttons' rest, hover and press keys in a *local*
    /// light or dark dictionary. Disabled, keyboard focus and Windows contrast themes keep their native states.
    public static void ButtonBrushes(ThemeTokens t, bool dark, bool desktop, Action<string, Rgba> put)
    {
        var plain = !dark && !desktop ? t.GroupedCard : t.Fill3;
        var edge = t.Label3.Alpha(desktop ? 0.55 : 0.28);
        foreach (var (state, wash) in new[] { ("", 0.0), ("PointerOver", 0.05), ("Pressed", 0.1) })
        {
            Rgba Face(Rgba fill) => wash == 0 ? fill : t.Label.Alpha(wash).Over(fill.Over(t.Page));
            var accent = Face(t.Tint);
            put("AccentButtonBackground" + state, accent);
            put("AccentButtonBorderBrush" + state, accent);
            put("AccentButtonForeground" + state, t.OnTint);
            put("ButtonBackground" + state, Face(plain));
            put("ButtonForeground" + state, t.Label);
            put("ButtonBorderBrush" + state, edge);
        }
    }
}
