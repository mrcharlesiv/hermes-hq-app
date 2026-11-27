namespace Hermes.Core.Transcripts;

/// A link chip on screen: its width, height and icon after UI Scale, and the room its words have beside the icon.
public sealed record ChipOnScreen(double Width, double Height, double Icon, double TextRoom);

/// [WIN-LINK-CHIP-SCALE] A link chip's metrics (App/Chat/Cells/LinkChipView.swift at 93f984bb1): `iconSize` 18 on the
/// Mac, `padH` 12, `padV` 10, the icon 8 from the words, the host 2 under the title; `height(style:)` = padV + the
/// chat's body line + 2 + its time line + padV. The Mac's line heights grow with the text size (`ChatStyle`
/// `.rounded(.up)`); on Windows the text size is UISettings.TextScaleFactor, which grows the words, so the lines and the
/// height follow it here. The icon and the 300 cap (`LinkChipFit`) don't: the Mac's `glyphScale` is 1, its words trim
/// inside a card that keeps its width.
///
/// UI Scale is one ScaleTransform over the window (Features/Settings/ThemeService `ApplyScale`): every number here is in
/// that layout's units and drawn × UI Scale once (`Layout`), as the iPhone's `300 * glyphScale`.
public static class LinkChipSize
{
    public const double IconSize = 18, PadH = 12, PadV = 10, LineGap = 2, IconGap = 8;
    /// The transcript's body and time sizes and lines at the default text size (MarkdownRenderer's 21 line).
    public const double TitleSize = 14, HostSize = 11, TitleLineAt100 = 21, HostLineAt100 = 15;

    /// Windows' text size as a factor; anything unknown (not a finite number above 0) is the default.
    public static double Text(double textScale) => double.IsFinite(textScale) && textScale > 0 ? textScale : 1;

    /// The title's line: 21 at the default text size, up to the next whole unit as it grows.
    public static double TitleLine(double textScale) => Up(TitleLineAt100 * Text(textScale));

    /// The host's line: 15 at the default text size.
    public static double HostLine(double textScale) => Up(HostLineAt100 * Text(textScale));

    /// padV + title line + 2 + host line + padV. Fixed for a given text size, so a title or icon arriving later never
    /// moves the transcript.
    public static double Height(double textScale) => PadV + TitleLine(textScale) + LineGap + HostLine(textScale) + PadV;

    /// The words' room in a chip `chipWidth` wide: bounds.width − (padH + iconSize + 8) − padH, never below 0.
    public static double TextRoom(double chipWidth) =>
        double.IsFinite(chipWidth) ? Math.Max(0, chipWidth - (PadH + IconSize + IconGap) - PadH) : 0;

    /// The chip as drawn in a reply column offering `column` layout units, at `uiScale` (the window's transform) and
    /// `textScale` (Windows' text size).
    public static ChipOnScreen Layout(double column, double uiScale, double textScale)
    {
        var ui = double.IsFinite(uiScale) && uiScale > 0 ? uiScale : 1;
        var width = LinkChipFit.Width(column);
        return new ChipOnScreen(width * ui, Height(textScale) * ui, IconSize * ui, TextRoom(width) * ui);
    }

    /// The host line cut in the middle to fit `room` (the Mac's `.byTruncatingMiddle`): the most characters that fit,
    /// split around one "…", the odd one at the start. Whole characters only (text elements, so an emoji or an accented
    /// letter is never split). "…" alone when nothing else fits, "" when not even that does.
    public static string MiddleTrim(string text, double room, Func<string, double> measure)
    {
        if (string.IsNullOrEmpty(text) || measure(text) <= room) return text ?? "";
        var info = new System.Globalization.StringInfo(text);
        var count = info.LengthInTextElements;
        string Cut(int keep)
        {
            var head = (keep + 1) / 2;
            var tail = keep - head;
            return info.SubstringByTextElements(0, head) + "…" + (tail > 0 ? info.SubstringByTextElements(count - tail, tail) : "");
        }
        if (measure("…") > room) return "";
        // The longest cut that fits: measured widths grow with the characters kept.
        int lo = 0, hi = count - 1;
        while (lo < hi)
        {
            var mid = (lo + hi + 1) / 2;
            if (measure(Cut(mid)) <= room) lo = mid; else hi = mid - 1;
        }
        return Cut(lo);
    }

    private static double Up(double value) => Math.Ceiling(value - 1e-9);
}
