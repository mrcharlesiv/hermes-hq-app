// [mac] Mac polish #101: where a window of its own (the Settings window) opens: beside the main window, inside the
// screen's visible part (clear of the menu bar and the Dock). Pure: unit tested in Tests/MacPolish1Tests.swift.

import CoreGraphics

nonisolated enum WindowFit {
    /// `frame` moved, and made smaller only if it can't fit, so that it lies inside `visible`; nil: as asked.
    static func inside(_ frame: CGRect, visible: CGRect?) -> CGRect {
        guard let visible, !visible.isEmpty else { return frame }
        let width = min(frame.width, visible.width), height = min(frame.height, visible.height)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - height), width: width, height: height)
    }

    /// An AppKit screen rectangle (origin at the main screen's bottom left, y up) in a window's system frame's terms
    /// (origin at the main screen's top left, y down). `main`: the main screen's AppKit frame.
    static func flipped(_ rect: CGRect, main: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: main.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
