namespace Hermes.Core.Attachments;

/// Frames for a message's photos (App/Chat/Attachments/MediaLayout.swift; spec 1x-attachments §7.3): known before any
/// pixel loads, so a bubble never changes height when its pictures arrive. Pure.
public static class MediaLayout
{
    public readonly record struct Frame(double X, double Y, double Width, double Height);

    /// One photo: w = min(maxW, 260), h from its shape; past 320 tall, h = 320 and w follows (at least 150); under 100
    /// tall, 100. Unknown size: (min(maxW, 260), 195).
    public static (double Width, double Height) Single(double maxWidth, int? pixelWidth, int? pixelHeight)
    {
        var w = Math.Min(maxWidth, 260);
        if (pixelWidth is not > 0 || pixelHeight is not > 0) return (w, 195);
        double pw = pixelWidth.Value, ph = pixelHeight.Value;
        var h = w * ph / pw;
        if (h > 320)
        {
            h = 320;
            w = Math.Max(150, Math.Min(maxWidth, 320 * pw / ph));
        }
        if (h < 100) h = 100;
        return (w, h);
    }

    /// Two or more photos: square tiles in two columns, 8 apart (side = floor((width − 8) / 2)). Three: the first runs
    /// across the top at the same height, two under it. More than four: four tiles, the last one dimmed under "+N".
    /// Returns the tiles and N (the photos without a tile).
    public static (IReadOnlyList<Frame> Tiles, int More) Grid(double width, int count)
    {
        width = Math.Min(width, 520);
        var side = Math.Floor((width - 8) / 2);
        const double gap = 8;
        if (count <= 1) return ([new Frame(0, 0, width, side)], 0);
        if (count == 2) return ([new Frame(0, 0, side, side), new Frame(side + gap, 0, side, side)], 0);
        if (count == 3)
            return ([new Frame(0, 0, side * 2 + gap, side), new Frame(0, side + gap, side, side), new Frame(side + gap, side + gap, side, side)], 0);
        return ([
            new Frame(0, 0, side, side), new Frame(side + gap, 0, side, side),
            new Frame(0, side + gap, side, side), new Frame(side + gap, side + gap, side, side),
        ], count - 4);
    }

    /// The grid's whole height for `count` photos at `width`.
    public static double GridHeight(double width, int count) =>
        Grid(width, count).Tiles.Max(f => f.Y + f.Height);
}
