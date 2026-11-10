// A sideways scroll bar runs in a lane of its own under what scrolls, never over it. Owner 2026-10-29: "the scrollbar
// (at least on horizontal scrolling) sits over the text in a bunch of places. make sure the scrollbar doesn't get in
// the way of anything."

import CoreGraphics

nonisolated enum ScrollBarLane {
    /// The room a strip that scrolls sideways keeps under its words for the system's bar. Measured in the running app
    /// (2026-10-29): on the iPhone and iPad the bar is 3 pt thick, 3 pt up from the strip's bottom (so 8 leaves 2 pt
    /// over it); [mac] on the Mac it is AppKit's scroller, a 15 pt track on the strip's bottom edge (its knob widens
    /// inside the track under the pointer). Code cards kept 10, the diff 8 and the chips 8: fine on the iPhone, while
    /// on the Mac the scroller sat on their last line.
    static var height: CGFloat { DeviceWord.isMac ? 15 : 8 }
}
