namespace Hermes.Core.Insights;

/// Pure view-mode and framing rules for Insights › Star Map.
public static class StarMapViewRules
{
    /// Mac Catalyst draws UIKit points at 77% screen scale; capping initial whole-map framing on Windows
    /// to 0.77 matches Mac's cluster footprint (~306 × 339 px at ~767 px width).
    public const double DesktopFitScale = 0.77;

    /// Determines whether Star Map should start in List mode.
    /// When a screen reader is active, Star Map always opens in List mode without modifying any saved preference.
    public static bool InitialListMode(string? savedPreference, bool screenReaderActive) =>
        screenReaderActive || string.Equals(savedPreference, "list", StringComparison.OrdinalIgnoreCase);
}
