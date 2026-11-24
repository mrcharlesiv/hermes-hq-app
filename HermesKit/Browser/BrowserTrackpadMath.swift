// The browser viewer's touch geometry (port of the web app's src/browser-watch/trackpad.ts math). The page keeps the
// bot's desktop layout and is drawn to fit; two fingers pinch to zoom it and pan it. Holding the browser, the screen is a
// trackpad: one finger moves a drawn pointer, a tap clicks where it is, a still hold (or a quick double-tap and drag)
// presses and drags, two fingers scroll. Pure: the stage view (App/Browser) feeds it touches.

import CoreGraphics
import Foundation

nonisolated enum BrowserTrackpadMath {
    static let tapSlop: CGFloat = 8
    /// A hardware pointer (Mac mouse/trackpad, iPad pointer) is steadier than a fingertip, so drags start sooner.
    static let directDragSlop: CGFloat = 4
    static let holdSeconds = 0.45
    static let doubleTapSeconds = 0.32
    /// A second touch this soon after and this close to a trackpad tap arms a drag on movement.
    static let doubleTapDragSeconds: TimeInterval = 0.28
    static let doubleTapDragReach: CGFloat = 36
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

    /// A stage point as fractions of the drawn page, kept on the page (a click in the margin beside it lands on its
    /// nearest edge); nil before the page has a size.
    static func clamped(_ point: CGPoint, in view: View) -> CGPoint? {
        let size = view.drawnSize
        guard size.width > 0, size.height > 0 else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - view.x) / size.width)), y: min(1, max(0, (point.y - view.y) / size.height)))
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

    /// True when a new finger touch lands quickly enough and close enough to a prior trackpad tap to arm a double-tap drag.
    static func isDoubleTapDrag(previous: (time: TimeInterval, point: CGPoint)?, at point: CGPoint, now: TimeInterval) -> Bool {
        guard let previous else { return false }
        let dt = now - previous.time
        return dt >= 0 && dt <= doubleTapDragSeconds && hypot(point.x - previous.point.x, point.y - previous.point.y) <= doubleTapDragReach
    }
}

/// One finger, or the mouse's button, on the page while this device holds the browser: what goes to the page as it
/// lands, waits, travels and lifts. Pure, so the two ways of pointing are tested without touches.
///
/// - `trackpad` (a finger on glass): the finger moves the drawn pointer from where it is. A tap clicks there. A still
///   hold presses the page's left button right away (with a haptic tick and grab ring) so press-and-hold controls and
///   sliders respond immediately, then dragging moves with the button held and lifting lets go. A quick second touch
///   after a tap (`armed: true`) also drags on movement (double-tap-and-drag) while still sending a second click if
///   lifted without moving (double-click).
/// - `direct` (a mouse or trackpad pointer: the Mac, an iPad's): the pointer is where the cursor is. A click clicks
///   there; pressing and moving drags at once, with no hold to wait for.
///
/// A tester (2026-11-16): "Drag and drop does not work in Watch Browser on Mac or iPhone." The hold marked the press
/// as already made (one flag was both "looks pressed" and "button is down"), so the press was never sent and a drag
/// only moved the pointer; the lift then released a button the page never saw go down.
nonisolated struct BrowserOneFinger: Sendable, Equatable {
    nonisolated enum Kind: Sendable { case trackpad, direct }
    nonisolated enum Out: Sendable, Equatable {
        /// The pointer draws pressed (a little smaller, with a grab ring) or not.
        case look(Bool)
        /// A tactile tick when a finger grabs on glass (hold or double-tap-and-drag; not on a Mac mouse).
        case haptic
        /// The page's left button goes down where the pointer is.
        case down
        /// The page's left button comes up where the pointer is.
        case up
        /// A click where the pointer is.
        case tap
    }

    let kind: Kind
    /// A press is owed to the first travel (`direct`: from the start; `trackpad`: after a quick preceding tap or once a hold runs).
    private(set) var armed: Bool
    /// The finger has travelled past the tap's slop (or moved while holding).
    private(set) var moved = false
    /// The page's button is down: a `down` went out and its `up` has not.
    private(set) var buttonDown = false

    init(kind: Kind, armed: Bool = false) {
        self.kind = kind
        self.armed = kind == .direct || armed
    }

    /// The still hold ran out (nothing for a finger/pointer that has already travelled, or a button already down).
    /// Presses the page's button right away so press-and-hold controls and sliders react before movement on both
    /// iPhone (with a haptic tick) and Mac/iPad pointer (no haptic).
    mutating func held() -> [Out] {
        guard !moved, !buttonDown else { return [] }
        armed = true
        buttonDown = true
        return kind == .direct ? [.look(true), .down] : [.look(true), .haptic, .down]
    }

    /// The first travel: presses when armed and not already down (`direct`, or `trackpad` double-tap-and-drag). Later
    /// travel only moves the pointer.
    mutating func travelled() -> [Out] {
        guard !moved else { return [] }
        moved = true
        guard armed, !buttonDown else { return [] }
        buttonDown = true
        return kind == .direct ? [.look(true), .down] : [.look(true), .haptic, .down]
    }

    /// The finger lifted: a held button lets go; a finger that never travelled and never held clicks (including the
    /// second tap of a double-click).
    mutating func lifted() -> [Out] {
        defer { armed = false }
        if buttonDown {
            buttonDown = false
            return [.up, .look(false)]
        }
        guard !moved else { return [] }
        return [.tap]
    }

    /// The touch was taken away (a second finger, a call, control lost): a held button is let go, nothing clicks.
    mutating func cancelled() -> [Out] {
        defer { armed = false }
        if buttonDown {
            buttonDown = false
            return [.up, .look(false)]
        }
        return []
    }
}
