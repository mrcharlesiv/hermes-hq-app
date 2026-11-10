// The browser viewer's touch geometry (port of the web app's src/browser-watch/trackpad.ts math). The page keeps the
// bot's desktop layout and is drawn to fit; two fingers pinch to zoom it and pan it. Holding the browser, the screen is a
// trackpad: one finger moves a drawn pointer, a tap clicks where it is, a still hold then a drag presses and drags, two
// fingers scroll. Pure: the stage view (App/Browser) feeds it touches.

import CoreGraphics

nonisolated enum BrowserTrackpadMath {
    static let tapSlop: CGFloat = 8
    static let holdSeconds = 0.45
    static let doubleTapSeconds = 0.32
    /// Past this a frame (at most 1920 px wide) is too soft to read.
    static let maxZoom: CGFloat = 4
    static let doubleTapZoom: CGFloat = 2.5
    /// A spread or squeeze this big makes two fingers a zoom rather than a scroll.
    static let pinchStart: CGFloat = 0.06
    static let flingDecay: CGFloat = 0.92
    /// Page points per ms.
    static let flingStop: CGFloat = 0.4
    /// A zoomed view pans to keep the pointer this far inside it.
    static let edge: CGFloat = 28

    /// The drawn page: `zoom` over its fitted size, its top-left at `x`, `y` in the stage.
    struct View: Equatable, Sendable {
        var zoom: CGFloat = 1
        var x: CGFloat = 0
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
        var drawnSize: CGSize { CGSize(width: width * zoom, height: height * zoom) }
        var frame: CGRect { CGRect(x: x, y: y, width: width * zoom, height: height * zoom) }
    }

    /// The page fitted into the stage, zoomed, and kept covering the stage (centred where it is smaller).
    static func place(stage: CGSize, page: CGSize?, zoom: CGFloat, x: CGFloat, y: CGFloat) -> View {
        let aspect: CGFloat
        if let page, page.width > 0, page.height > 0 { aspect = page.width / page.height } else { aspect = stage.width / max(1, stage.height) }
        let width = min(stage.width, stage.height * aspect), height = width / max(aspect, 0.0001)
        let level = min(maxZoom, max(1, zoom))
        func along(_ offset: CGFloat, _ drawn: CGFloat, _ room: CGFloat) -> CGFloat {
            drawn <= room ? (room - drawn) / 2 : min(0, max(room - drawn, offset))
        }
        return View(zoom: level, x: along(x, width * level, stage.width), y: along(y, height * level, stage.height),
                    width: width, height: height)
    }

    /// Zoom by `factor` about a stage point, keeping the page point under it in place.
    static func zoom(_ view: View, by factor: CGFloat, about at: CGPoint, stage: CGSize, page: CGSize?) -> View {
        let zoom = min(maxZoom, max(1, view.zoom * factor)), ratio = zoom / view.zoom
        return place(stage: stage, page: page, zoom: zoom, x: at.x - (at.x - view.x) * ratio, y: at.y - (at.y - view.y) * ratio)
    }

    /// Moves a pointer (fractions of the page) by finger travel in points, 1:1 with the drawn page.
    static func move(_ pointer: CGPoint, dx: CGFloat, dy: CGFloat, drawn: CGSize) -> CGPoint {
        guard drawn.width > 0, drawn.height > 0 else { return pointer }
        return CGPoint(x: min(1, max(0, pointer.x + dx / drawn.width)), y: min(1, max(0, pointer.y + dy / drawn.height)))
    }

    /// Two-finger travel in points as page scroll in page pixels (fingers up scroll the page down).
    static func scrollDelta(dx: CGFloat, dy: CGFloat, drawn: CGSize, page: CGSize?) -> CGVector {
        let sx = page.map { drawn.width > 0 ? $0.width / drawn.width : 1 } ?? 1
        let sy = page.map { drawn.height > 0 ? $0.height / drawn.height : 1 } ?? 1
        return CGVector(dx: -dx * sx, dy: -dy * sy)
    }

    /// A stage point as fractions of the drawn page, or nil outside it.
    static func fraction(_ point: CGPoint, in view: View) -> CGPoint? {
        let size = view.drawnSize
        guard size.width > 0, size.height > 0 else { return nil }
        let p = CGPoint(x: (point.x - view.x) / size.width, y: (point.y - view.y) / size.height)
        return (0...1).contains(p.x) && (0...1).contains(p.y) ? p : nil
    }

    /// How far a zoomed view must pan to keep the pointer `edge` inside the stage.
    static func follow(pointer: CGPoint, view: View, stage: CGSize) -> CGVector {
        guard view.zoom > 1 else { return .zero }
        let size = view.drawnSize
        let px = view.x + pointer.x * size.width, py = view.y + pointer.y * size.height
        let dx = px < edge ? edge - px : px > stage.width - edge ? stage.width - edge - px : 0
        let dy = py < edge ? edge - py : py > stage.height - edge ? stage.height - edge - py : 0
        return CGVector(dx: dx, dy: dy)
    }
}
