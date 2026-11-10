// [density] Theme › Density in the iOS look: the Bots and Sessions pages' faces and rows at Standard or Compact, both
// × UI Scale (a tester 2026-11-08, who used the Desktop Look at 90 % to fit more; owner: "UI scaling everywhere that
// makes sense"). The Desktop Look keeps its own rows (`DesktopRows`), already compact.

import UIKit

enum Density {
    /// Compact, in the iOS look.
    static var compact: Bool { ThemeTable.current.state.compact }

    /// An iOS-look length at the density in use, × UI Scale. Gutters stay as they are: they line the rows up with the
    /// bars and headers, which don't change.
    static func ios(_ standard: CGFloat, _ compact: CGFloat) -> CGFloat { HQFont.scaled(Self.compact ? compact : standard) }
}
