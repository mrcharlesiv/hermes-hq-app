using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// About's two groups (SettingsRootView) and the insets around their labels (MacPush).
/// Input widths are the measured native controls, not estimates from the words or the window size.
public readonly record struct SettingsFileActionMetrics(double FontSize, double Unit, double CardEdge, double FocusRoom)
{
    public double ButtonSide => 12 * Unit;
    public double ButtonVertical => 4 * Unit;
    public double Gap => 10 * Unit;
    public double RowGap => 8 * Unit;
    // Kit.Card already consumes its stroke. The focus visual must still fit *inside* the horizontal viewport.
    public double SideInset => Math.Max(FocusRoom, 20 * Unit - CardEdge);
    public double VerticalInset => Math.Max(FocusRoom, 8 * Unit - CardEdge);

    public static SettingsFileActionMetrics For(ThemeState state, bool inMainFrame, double cardEdge = 0, double focusRoom = 0)
    {
        // HQFont's default-size body. WinUI still applies the person's Windows text size to the button.
        // Only the main frame has ThemeService.ApplyScale; the separate Settings window is untransformed.
        var unit = ChatStyle.Catalyst / (inMainFrame ? state.Scale : 1);
        var points = (state.DesktopLook ? 15 : 17) * (state.Scale * ChatStyle.MacBase(state.DesktopLook));
        points = Math.Round(points * 2, MidpointRounding.AwayFromZero) / 2;
        if (state.DesktopLook) points = Math.Max(ChatStyle.MacSmallest, points);
        return new(points * unit, unit, cardEdge, focusRoom);
    }

    /// The fixed-size horizontal candidate includes just one gap *between* the pairs. If it doesn't fit,
    /// keep the two pairs even when a very narrow viewport has to scroll to see the end of the longer one.
    public SettingsFileActionRows Fit(double viewport, double fileWidth, double fileHeight, double resetWidth, double resetHeight)
    {
        var sides = 2 * SideInset;
        var ends = 2 * VerticalInset;
        var inline = sides + (fileWidth + Gap + resetWidth);
        // WinRT rounds the viewport and both DesiredSizes independently to float. At equality they
        // can disagree by one float step. Compare the unrounded sum, so a larger shortage still wraps.
        var shortage = inline - viewport;
        if (shortage > 0 && (inline > MathF.BitIncrement((float)viewport) || shortage >= Gap))
            return new(sides + Math.Max(fileWidth, resetWidth), ends + fileHeight + RowGap + resetHeight,
                VerticalInset, SideInset, VerticalInset + fileHeight + RowGap);
        var height = Math.Max(fileHeight, resetHeight);
        // Absorb only that rounding residue in the gap, not in the button widths or the scroll extent.
        var width = Math.Min(viewport, inline);
        var secondX = SideInset + fileWidth + Gap - Math.Max(0, shortage);
        return new(width, ends + height, VerticalInset + (height - fileHeight) / 2,
            secondX, VerticalInset + (height - resetHeight) / 2);
    }
}

public readonly record struct SettingsFileActionRows(double Width, double Height, double FirstY, double SecondX, double SecondY);

/// The ScrollViewer is measured in its card slot; the buttons fit its content viewport, never its scroll extent.
public sealed class SettingsFileActionViewport
{
    private (double Offer, double Slot, double Viewport)? _arranged;
    private (double Slot, double Viewport) _measured;
    private double _offer;

    public (double Slot, double Viewport) Measure(double offer)
    {
        _offer = offer;
        var slot = _arranged is { } last && last.Offer == offer ? last.Slot : offer;
        var viewport = _arranged is { } at && at.Slot == slot ? at.Viewport : slot;
        return _measured = (slot, viewport);
    }

    /// A changed allocation needs another measure so the page receives the new card height.
    public bool Arrange(double slot, double viewport)
    {
        _arranged = (_offer, slot, viewport);
        return _measured != (slot, viewport);
    }
}
