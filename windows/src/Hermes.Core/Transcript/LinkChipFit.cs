namespace Hermes.Core.Transcripts;

/// [WIN-LINK-CHIP-FIT] A link chip's width (App/Chat/Cells/LinkChipView.swift `width(maxText:)` at 93f984bb1:
/// `min(maxText, 300 * HQFont.glyphScale)`): the room the reply's words have, up to the cap. Its title never decides it,
/// so a title that arrives later can't move the transcript.
///
/// UI Scale on Windows is one ScaleTransform over the whole window's content (Features/Settings/ThemeService
/// `ApplyScale`): the content is laid out at 1/scale of the window and drawn scaled up. So the cap here is in that
/// layout's units and is NOT multiplied by the scale again: 300 of them already draw as 300 × UI Scale on screen, as
/// the Mac's `300 * glyphScale`. Multiplying would apply UI Scale twice.
public static class LinkChipFit
{
    /// The Mac's 300 pt, in the transcript's layout units.
    public const double MaxWidth = 300;

    /// The chip's width in a column that offers `available` (after the chip's own margins): the whole column when it
    /// is narrower than the cap, else the cap. An unbounded column (infinity) gets the cap; nothing (≤ 0 or NaN) gets 0.
    public static double Width(double available)
    {
        if (double.IsNaN(available) || available <= 0) return 0;
        return Math.Min(available, MaxWidth);
    }
}
