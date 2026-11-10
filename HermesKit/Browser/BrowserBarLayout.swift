// Watch Browser's in-control bar: its five icons and Give Back on one row, or Give Back on a full-width row under the
// icons. Not only at accessibility text sizes: at Extra Large the one row can already run past the margins on a 375 pt
// phone and squeeze Give Back to "Give / Back" (UX study 2026-10-19 #84). Pure: the viewer measures, this decides.

import CoreGraphics

nonisolated enum BrowserBarLayout {
    /// The gap between the icons and Give Back.
    static let spacing: CGFloat = 8
    /// The bar's 16 pt margins on both sides.
    static let margins: CGFloat = 32

    /// Stacks when the text size is an accessibility one, or when the one row is wider than the space between the
    /// margins. A width of 0 (the screen not laid out yet) decides by text size alone.
    static func stacks(accessibility: Bool, icons: CGFloat, give: CGFloat, width: CGFloat) -> Bool {
        if accessibility { return true }
        guard width > 0 else { return false }
        return icons + spacing + give > width - margins
    }
}
