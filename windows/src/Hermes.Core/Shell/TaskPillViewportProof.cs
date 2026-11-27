using System.Drawing;

namespace Hermes.Core.Shell;

/// Whether any of a laid-out Tasks pill's painted fill is visible. All bounds are in window root coordinates.
public static class TaskPillViewportProof
{
    public enum Boundary { ContentViewport, ScrollViewer, Root }

    /// The scroll boundaries on the fill's own visual path, innermost first, then the window root.
    /// Each ScrollViewer must have a measured content viewport: the outside of the rail includes its padding.
    /// Null means the clipping path wasn't resolved, not that the pill was measured outside it.
    public static bool? InView(RectangleF fill, IEnumerable<(Boundary Part, RectangleF Bounds)> ancestors)
    {
        static bool Measured(RectangleF r) => float.IsFinite(r.Left) && float.IsFinite(r.Top)
            && float.IsFinite(r.Right) && float.IsFinite(r.Bottom) && r.Width >= 0 && r.Height >= 0;
        if (!Measured(fill)) return null;
        bool pendingViewport = false, sawRail = false;
        foreach (var (part, bounds) in ancestors)
        {
            if (!Measured(bounds)) return null;
            fill.Intersect(bounds);
            switch (part)
            {
                case Boundary.ContentViewport when !pendingViewport:
                    pendingViewport = true;
                    break;
                case Boundary.ScrollViewer when pendingViewport:
                    pendingViewport = false;
                    sawRail = true;
                    break;
                case Boundary.Root when sawRail && !pendingViewport:
                    return fill.Width > 0 && fill.Height > 0;
                default: return null;
            }
        }
        return null;
    }
}
