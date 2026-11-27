// Watch Browser's in-control bar: its five icons and Give Back on one row, or Give Back on a full-width row under the
// icons. C# twin of HermesKit/Browser/BrowserBarLayout.swift. Pure: the viewer measures, this decides.

namespace Hermes.Core.Browser;

public static class BrowserBarLayout
{
    /// The gap between the icons and Give Back.
    public const double Spacing = 8;
    /// The bar's 16 pt margins on both sides.
    public const double Margins = 32;

    /// Stacks when the text size is an accessibility one, or when the one row is wider than the space between the
    /// margins. A width of 0 (the screen not laid out yet) decides by text size alone.
    public static bool Stacks(bool accessibility, double icons, double give, double width)
    {
        if (accessibility) return true;
        if (width <= 0) return false;
        return icons + Spacing + give > width - Margins;
    }
}
