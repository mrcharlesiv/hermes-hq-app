using Hermes.Core.Bots;

namespace Hermes.Core.Transcripts;

/// Mac 1250 ChatFindBar.wantsStacked(width:) and ChatViewController.showFindBar(_:).
/// The panel supplies its usable width (excluding edit chrome) and the current font metrics.
public static class ChatFindLayout
{
    public const double MinimumField = 88, Arrow = 44, Gap = 4, AfterCount = 10;
    public const double MinimumHeight = 48, InsetGap = 8;

    public static bool Stacked(double contentWidth, double countReserve, double liveCount, double doneWidth, double textScale, bool previous)
    {
        if (UndoPillClock.AccessibilityTextScale(textScale)) return true;
        if (contentWidth <= 0) return previous;
        var count = Math.Ceiling(Math.Max(countReserve, liveCount));
        return contentWidth < MinimumField + Gap + count + AfterCount + 2 * Arrow + Gap + doneWidth;
    }

    public static double TranscriptTop(double original, bool open, double drawnHeight) =>
        open ? original + (drawnHeight > 0 ? drawnHeight : MinimumHeight) + InsetGap : original;
}
