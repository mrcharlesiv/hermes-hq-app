// [WIN-THINKING-TEXT-STYLE] The chat's notice font (`style.notice`) as numbers, from the shipping Mac at 93f984bb1:
//   - App/Chat/ChatStyle.swift: `notice = font(.footnote)` (regular; Bold Text's semibold step is not on Windows).
//   - App/Theme/ThemeFonts.swift `HQFont.preferred`: the Desktop Look draws `desktopSpec(.footnote)` (12.5) ×
//     `factor` (Dynamic Type's body ratio × UI Scale, capped at iOS's largest text, `ratioCap` 53/17) on a half point,
//     never under `legible`'s 15 (`macSmallest`); the iOS look draws iOS's own footnote for the text size × `iosFactor`
//     (UI Scale, capped the same way) on a half point, or the system's footnote untouched when that factor is 1.
//   - HermesKit/Theme/ThemeState.swift `scale`: UI Scale × the look's Mac base (1.3 in the Desktop Look, 1.15 in the
//     iOS look; `macBody` 1).
//   - App/Theme/MacTypeSteps.swift: Catalyst draws the window at 77 %, so app points × 0.77 are the screen's points
//     (the type-steps trial is off in Release, so no snapping).
//   - App/Chat/Cells/ChatCells.swift `ChatWaitingCell.configure`: the words in `notice`, the timer in
//     `HQFont.monoDigitFace(ofSize: notice.pointSize)` (steady-width digits, owner 2026-10-27), which is the skin's own
//     face (no steady digits) when the Desktop Look draws a skin's typeface.
//   - `UIFont.lineHeight` of the system font, measured on Catalyst on this Mac (macOS 27): round(ascender) +
//     round(−descender), the ascender 0.966796875 and descender 0.2109375 of the size (15 → 18, 16.5 → 19, 13 → 16,
//     17 → 20). `WaitingLayout.Make` takes it (`ceil(style.notice.lineHeight)`).
//
// Windows draws the transcript's words at the Mac's screen points (MessageView: body 14, times 11, notes 12), so the
// notice comes out at 16.5 × 0.77 = 12.705 in the Desktop Look and 15 × 0.77 = 11.55 in the iOS look at UI Scale 100 %.
// UI Scale is one transform over the window (ThemeService `ApplyScale`), so a size here is divided by it once. Windows'
// text size (UISettings.TextScaleFactor) stands in for Dynamic Type: WinUI grows every TextBlock by it itself (the
// TextScaleWalk keeps that on), so the font size is the Mac's at the default text size, while the line the row lays
// out follows the Mac's footnote at the Dynamic Type size nearest below Windows' factor.

namespace Hermes.Core.Transcripts;

/// The notice font for one look, UI Scale and text size. `FontSize` and `LineHeight` are in the window's layout units
/// (before the UI Scale transform); `FontSize` is before WinUI's own text scaling; `LineHeight` already carries it.
public sealed record NoticeFont(double FontSize, double LineHeight, int Weight, double MacPoints, double MacLineHeight);

public static class ChatStyle
{
    /// Catalyst's iPad idiom draws the window at 77 % (`MacTypeSteps.catalyst`).
    public const double Catalyst = 0.77;
    /// iOS's largest text over its default (AX5 body 53 pt / 17 pt): Dynamic Type × UI Scale never goes past it.
    public const double RatioCap = 53.0 / 17.0;
    /// The Mac's smallest text style size in app points (`HQFont.macSmallest`, 11.55 on the screen).
    public const double MacSmallest = 15;
    /// The desktop's footnote (`desktopSpec(.footnote)`): 12.5, regular.
    public const double DesktopFootnote = 12.5;
    public const int NoticeWeight = 400;
    /// The system font's ascender and descender over its size (Catalyst `UIFont.systemFont`, measured).
    public const double Ascender = 0.966796875, Descender = 0.2109375;

    /// iOS's Dynamic Type sizes: body and footnote in points (xSmall … AX5). Large (index 3) is the default.
    public static readonly IReadOnlyList<(string Name, double Body, double Footnote)> Categories =
    [
        ("xSmall", 14, 12), ("small", 15, 12), ("medium", 16, 12), ("large", 17, 13), ("xLarge", 19, 15),
        ("xxLarge", 21, 17), ("xxxLarge", 23, 19), ("AX1", 28, 23), ("AX2", 33, 27), ("AX3", 40, 33),
        ("AX4", 47, 38), ("AX5", 53, 44),
    ];
    public const int DefaultCategory = 3;

    /// The look's Mac base (`ThemeState.macBase`).
    public static double MacBase(bool desktopLook) => desktopLook ? 1.3 : 1.15;

    /// Windows' text size as a factor; anything unknown is the default.
    public static double Text(double textScale) => double.IsFinite(textScale) && textScale > 0 ? textScale : 1;

    /// The Dynamic Type size Windows' text size stands for: the largest whose body ratio (body / 17) is at most the
    /// factor. 1.0 is Large, 1.5 xxxLarge (23/17 = 1.35), 1.65 AX1 (28/17 = 1.65), Windows' largest 2.25 AX2.
    public static int Category(double textScale)
    {
        var factor = Text(textScale);
        if (factor == 1) return DefaultCategory;
        var at = 0;
        for (var i = 0; i < Categories.Count; i++)
            if (Categories[i].Body / 17 <= factor + 1e-9) at = i;
        return at;
    }

    /// Swift's `.rounded()` on a half point.
    private static double Half(double v) => Math.Round(v * 2, MidpointRounding.AwayFromZero) / 2;

    /// `style.notice.pointSize` in the Mac's app points (before Catalyst's 77 %).
    public static double NoticePoints(bool desktopLook, int uiScalePercent, double textScale)
    {
        var (_, body, footnote) = Categories[Category(textScale)];
        var ratio = body / 17;
        var scale = Math.Max(1, uiScalePercent) / 100.0 * MacBase(desktopLook);
        if (desktopLook)
        {
            var factor = Math.Min(ratio * scale, Math.Max(RatioCap, ratio));
            return Math.Max(MacSmallest, Half(DesktopFootnote * factor));
        }
        var ios = Math.Min(scale, Math.Max(1, RatioCap / ratio));
        return ios == 1 ? footnote : Half(footnote * ios);
    }

    /// `UIFont.lineHeight` of the system font at `points` (Catalyst): round(ascender) + round(−descender).
    public static double MacLineHeight(double points) =>
        Math.Round(points * Ascender, MidpointRounding.AwayFromZero) + Math.Round(points * Descender, MidpointRounding.AwayFromZero);

    /// The words' font: its size at the default text size and the line at Windows' text size, on the screen's points
    /// and divided by UI Scale (the window's transform scales them back).
    public static NoticeFont Notice(bool desktopLook, int uiScalePercent, double textScale)
    {
        var ui = Math.Max(1, uiScalePercent) / 100.0;
        var atDefault = NoticePoints(desktopLook, uiScalePercent, 1);
        var now = NoticePoints(desktopLook, uiScalePercent, textScale);
        var line = MacLineHeight(now);
        return new NoticeFont(atDefault * Catalyst / ui, line * Catalyst / ui, NoticeWeight, now, line);
    }

    /// The typeface the words take: the skin's in the Desktop Look (`HQFont.face` with `skin.sansFamily`), else the
    /// system's (null: the window's own).
    public static string? NoticeFamily(bool desktopLook, string? skinSansFamily) =>
        desktopLook && !string.IsNullOrEmpty(skinSansFamily) ? skinSansFamily : null;

    /// Whether the timer's digits keep one width (`HQFont.monoDigitFace`): the system font's monospaced digits, except
    /// when the Desktop Look draws a skin's typeface, where the Mac makes the skin's plain face.
    public static bool TimerTabular(bool desktopLook, string? skinSansFamily) => NoticeFamily(desktopLook, skinSansFamily) == null;
}
