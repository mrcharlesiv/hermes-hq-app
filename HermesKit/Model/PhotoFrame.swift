// [photoheads] Move and Scale for a bot photo (docs/spec/3x-photoheads.md §7.2): where the picture sits in the square
// frame. A line-for-line port of the web app's `src/ui-bots/photo-frame-model.ts`. Lengths are in frame sides (1 = the
// frame's width), so a frame that resizes keeps the placement; x and y are the photo centre's offset from the frame
// centre. Zoom 1 fills the frame with the photo's short side; the smallest zoom fits the whole photo in.

import CoreGraphics
import Foundation

nonisolated struct PhotoFrame: Equatable, Sendable {
    var zoom: Double
    var x: Double
    var y: Double

    static let maxZoom = 5.0
    static let start = PhotoFrame(zoom: 1, x: 0, y: 0)

    /// A photo's width and height as plain numbers; a side that is not a positive, finite length counts as 0.
    private static func sides(_ photo: CGSize) -> (width: Double, height: Double) {
        func side(_ value: CGFloat) -> Double { value.isFinite && value > 0 ? Double(value) : 0 }
        return (side(photo.width), side(photo.height))
    }

    /// The zoom that fits the whole photo inside the frame (`min(w, h) / max(w, h)`, 1 for an empty size).
    static func minZoom(_ photo: CGSize) -> Double {
        let (width, height) = sides(photo)
        let short = min(width, height), long = max(width, height)
        guard long > 0, short > 0 else { return 1 }
        return short / long
    }

    /// The photo's drawn size at this zoom, in frame sides.
    static func drawnSize(_ photo: CGSize, zoom: Double) -> CGSize {
        let (width, height) = sides(photo)
        var short = min(width, height)
        if !(short > 0) { short = 1 }
        return CGSize(width: width / short * zoom, height: height / short * zoom)
    }

    private static func within(_ value: Double, _ limit: Double) -> Double { max(-limit, min(limit, value)) }

    private static func clampZoom(_ zoom: Double, _ photo: CGSize) -> Double {
        let value = zoom.isFinite ? zoom : 1
        return max(minZoom(photo), min(maxZoom, value))
    }

    /// A photo larger than the frame always covers it; a smaller one stays inside it.
    func clamped(_ photo: CGSize) -> PhotoFrame {
        let zoom = Self.clampZoom(self.zoom, photo)
        let drawn = Self.drawnSize(photo, zoom: zoom)
        return PhotoFrame(zoom: zoom,
                          x: Self.within(x.isFinite ? x : 0, abs(Double(drawn.width) - 1) / 2),
                          y: Self.within(y.isFinite ? y : 0, abs(Double(drawn.height) - 1) / 2))
    }

    func panned(_ photo: CGSize, dx: Double, dy: Double) -> PhotoFrame {
        PhotoFrame(zoom: zoom, x: x + dx, y: y + dy).clamped(photo)
    }

    /// Zooms by `ratio` keeping the point under the fingers (frame-centre relative) where it is.
    func zoomed(_ photo: CGSize, ratio: Double, focusX: Double = 0, focusY: Double = 0) -> PhotoFrame {
        let next = Self.clampZoom(zoom * ratio, photo)
        let applied = zoom > 0 ? next / zoom : 1
        return PhotoFrame(zoom: next, x: focusX + (x - focusX) * applied, y: focusY + (y - focusY) * applied).clamped(photo)
    }

    /// Where the photo lands on a square canvas `edge` wide (origin top-left).
    func rect(_ photo: CGSize, edge: Double) -> CGRect {
        let drawn = Self.drawnSize(photo, zoom: zoom)
        let width = Double(drawn.width) * edge, height = Double(drawn.height) * edge
        return CGRect(x: edge / 2 + x * edge - width / 2, y: edge / 2 + y * edge - height / 2, width: width, height: height)
    }

    /// Whether part of the frame shows no photo (zoomed out past filling it).
    func leavesGaps(_ photo: CGSize) -> Bool {
        let drawn = Self.drawnSize(photo, zoom: zoom)
        return Double(drawn.width) < 1 - 1e-6 || Double(drawn.height) < 1 - 1e-6
    }
}
