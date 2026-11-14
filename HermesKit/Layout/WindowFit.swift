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

    // MARK: Remembered and cascaded windows (Mac feel list, section D #29)

    /// A window's frame as kept between openings: "x,y,width,height" in whole points.
    static func encode(_ frame: CGRect) -> String {
        [frame.minX, frame.minY, frame.width, frame.height].map { String(Int($0.rounded())) }.joined(separator: ",")
    }

    /// The frame `encode` wrote, or nil for anything else (nothing kept yet, a damaged value, a size under `minimum`).
    static func decode(_ text: String?, minimum: CGSize) -> CGRect? {
        guard let parts = text?.split(separator: ",").map({ Double($0) }), parts.count == 4 else { return nil }
        let numbers = parts.compactMap { $0 }
        guard numbers.count == 4, numbers[2] >= minimum.width, numbers[3] >= minimum.height else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// Where the next window of a kind opens: at `frame`, or one `step` down and right of it for every window of that
    /// kind already sitting there (`taken`: their top left corners), as Finder's and Preview's windows do, so a second
    /// one never hides the first. Past the screen's foot or right edge it starts again a step in from the top left.
    static func cascaded(_ frame: CGRect, taken: [CGPoint], step: CGFloat = 28, visible: CGRect?) -> CGRect {
        func isTaken(_ rect: CGRect) -> Bool { taken.contains { abs($0.x - rect.minX) < 4 && abs($0.y - rect.minY) < 4 } }
        var out = inside(frame, visible: visible)
        var wrapped = false
        for _ in 0..<40 where isTaken(out) {
            let next = out.offsetBy(dx: step, dy: step)
            if let visible, !visible.isEmpty, next.maxX > visible.maxX + 0.5 || next.maxY > visible.maxY + 0.5 {
                if wrapped { break }
                wrapped = true
                out = inside(CGRect(x: visible.minX + step, y: visible.minY + step, width: out.width, height: out.height), visible: visible)
            } else {
                out = next
            }
        }
        return out
    }
}
