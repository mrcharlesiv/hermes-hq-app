namespace Hermes.Core.Screen;

/// [WIN-SCREEN-SETUP-LAYOUT] The latest-screenshots page's frame (93f984bb1 App/Screen/LatestScreenshotsView.swift,
/// §5.14): a scrolling page whose stack is 16 in from each side, 8 under the top and 24 over the bottom; the heading,
/// its line, the picture's rounded frame, the caption (12 under the frame) and then the setup card. The frame is 16:10 of
/// its width until a picture loads, then the picture's own shape within 0.3…2.2; with no picture it holds the status
/// line, at least 14 inside its top and bottom.
///
/// On the Mac that page fills the viewer, which covers the window's right pane, so a 16:10 empty frame is a few hundred
/// points tall and the card's buttons are in view under it. Windows opens the Screen in its own 1000 × 700 window: the
/// frame was 952 wide, 16:10 made it 595 tall and Set Up with Hermes sat below the window (CI shot 207). So a frame with
/// no picture is the Mac's 16:10 at most, and no taller than leaves the card's buttons in view (`Room`); never shorter
/// than its status line and insets. A loaded picture keeps its shape as on the Mac, and the page scrolls to the card.
public static class ScreenshotsLayout
{
    /// The frame before a picture loads: `frameView.heightAnchor … multiplier: 10.0 / 16.0`.
    public const double EmptyAspect = 10.0 / 16.0;
    /// A picture's shape is kept within these (`min(2.2, max(0.3, height / width))`).
    public const double MinAspect = 0.3;
    public const double MaxAspect = 2.2;
    /// The status line's least distance from the frame's top and bottom.
    public const double StatusInset = 14;
    /// The page's stack: in from each side, under the top, over the bottom.
    public const double Side = 16;
    public const double Top = 8;
    public const double Bottom = 24;
    /// Under the frame, caption or not (`setCustomSpacing(12, after: frameView)`).
    public const double FrameGap = 12;

    /// A picture's frame shape (height over width), kept within reason; no width: the empty frame's.
    public static double Aspect(double width, double height) =>
        width <= 0 || height <= 0 ? EmptyAspect : Math.Min(MaxAspect, Math.Max(MinAspect, height / width));

    /// The height an empty frame may take and still leave the card's buttons in view: the page's visible height, less
    /// where the frame starts on the page, less the run from the frame's bottom to the buttons' bottom (the gap, the
    /// caption, the card down to its buttons, none of which depends on the frame), less the page's bottom inset.
    public static double Room(double viewport, double frameTop, double frameToButtons) =>
        viewport - frameTop - frameToButtons - Bottom;

    /// The frame's height for its width. `aspect` null: no picture (the Mac's 16:10, capped by `room`, at least the
    /// status line and its insets). A picture: its own (clamped) shape, never squeezed.
    public static double FrameHeight(double width, double? aspect, double room, double statusHeight)
    {
        if (width <= 0) return 0;
        if (aspect is { } a) return width * Math.Min(MaxAspect, Math.Max(MinAspect, a));
        var least = Math.Max(0, statusHeight) + 2 * StatusInset;
        return Math.Max(least, Math.Min(width * EmptyAspect, room));
    }
}
