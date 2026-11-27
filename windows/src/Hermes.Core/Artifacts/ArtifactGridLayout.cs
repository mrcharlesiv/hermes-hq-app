namespace Hermes.Core.Artifacts;

/// The number of slots across a full row, and the absolute width of each (square for an image).
public readonly record struct ArtifactGridTrack(int Columns, double ItemWidth);

/// Unpinned images and day cards (ArtifactsViewController.gridImagesLayout/gridCardsLayout, Mac 1245).
public readonly record struct ArtifactGridLayout(ArtifactGridTrack Images, ArtifactGridTrack Cards)
{
    public const double Inset = 20, Gap = 12;
    private const double TrailingLane = 8; // ScrollBarLane.listTrailing; keep adds it to the section once.

    public static ArtifactGridLayout Fit(double listWidth, double viewportWidth, double? detailListWidth = null)
    {
        static double Measured(double value) => double.IsFinite(value) ? Math.Max(0, value) : 0;
        var outer = Measured(listWidth);
        // Opening a file fixes the list column before the next native measure. Do not draw into the new pane.
        if (detailListWidth is { } fixedWidth) outer = Math.Min(outer, Measured(fixedWidth));
        // Both measurements precede the panel padding. A narrower native viewport already paid some or all of the lane.
        var width = Math.Max(0, Math.Min(outer - TrailingLane, Measured(viewportWidth)) - 2 * Inset);
        int Columns(double least, int minimum) => Math.Max(minimum, (int)((width + Gap) / (least + Gap)));
        ArtifactGridTrack Track(int columns) => new(columns, Math.Max(0, Math.Floor((width - (columns - 1) * Gap) / columns)));
        return new(Track(Columns(150, 3)), Track(detailListWidth.HasValue ? 1 : Columns(300, 1)));
    }
}
