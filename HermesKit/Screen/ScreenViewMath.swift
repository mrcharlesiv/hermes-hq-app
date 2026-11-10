// The Screen's view math and touch rules (docs/spec/3x-screen.md §5.5, §5.7), a port of the web app's
// src/bot-screen-phone.tsx: the zoomed view, the relative-trackpad pointer, and the touch state machine. Pure values,
// so every rule is tested without a view.

import CoreGraphics
import Foundation

/// A zoomed view of the stage: the stage's content scaled by `zoom` about its top-left, then moved by (x, y).
nonisolated struct ScreenView: Equatable, Sendable {
    var zoom: CGFloat = 1
    var x: CGFloat = 0
    var y: CGFloat = 0
    static let fit = ScreenView()
}

nonisolated enum ScreenViewMath {
    static let tapSlop: CGFloat = 10
    static let longPress: TimeInterval = 0.55
    static let doubleTap: TimeInterval = 0.32
    static let doubleTapReach: CGFloat = 30
    static let maxZoom: CGFloat = 5
    static let doubleTapZoom: CGFloat = 2.5
    static let wheelTravel: CGFloat = 24
    static let keepClear: CGFloat = 40

    /// Keep a zoomed view covering its viewport: offsets stay within [size − size·zoom, 0].
    static func clampView(_ view: ScreenView, width: CGFloat, height: CGFloat) -> ScreenView {
        let zoom = min(maxZoom, max(1, view.zoom))
        func clamp(_ value: CGFloat, _ size: CGFloat) -> CGFloat { min(0, max(size - size * zoom, value)) }
        return ScreenView(zoom: zoom, x: clamp(view.x, width), y: clamp(view.y, height))
    }

    /// Zoom by `factor` about the viewport point `at`, keeping the content under it in place.
    static func zoomAbout(_ view: ScreenView, factor: CGFloat, at: CGPoint, width: CGFloat, height: CGFloat) -> ScreenView {
        let zoom = min(maxZoom, max(1, view.zoom * factor))
        let ratio = zoom / view.zoom
        return clampView(ScreenView(zoom: zoom, x: at.x - (at.x - view.x) * ratio, y: at.y - (at.y - view.y) * ratio), width: width, height: height)
    }

    /// Clamp to the desktop as drawn (it keeps the framebuffer's `aspect`, width ÷ height) rather than to the stage:
    /// panning never reaches the letterbox bands, and a desktop narrower or shorter than the view stays centred.
    static func clampToDesktop(_ view: ScreenView, width: CGFloat, height: CGFloat, aspect: CGFloat) -> ScreenView {
        let base = clampView(view, width: width, height: height)
        guard aspect > 0, width > 0, height > 0 else { return base }
        let zoom = base.zoom
        let drawnWidth = min(width, height * aspect) * zoom, drawnHeight = min(height, width / aspect) * zoom
        let left = (width * zoom - drawnWidth) / 2
        let x = drawnWidth >= width ? min(-left, max(width - left - drawnWidth, view.x)) : (width - drawnWidth) / 2 - left
        let y = drawnHeight >= height ? min(0, max(height - drawnHeight, view.y)) : (height - drawnHeight) / 2
        return ScreenView(zoom: zoom, x: x.isFinite ? x : 0, y: y.isFinite ? y : 0)
    }

    /// The desktop's size at fit (zoom 1) inside a stage.
    static func fitted(width: CGFloat, height: CGFloat, aspect: CGFloat) -> CGSize {
        guard aspect > 0, width > 0, height > 0 else { return .zero }
        return CGSize(width: min(width, height * aspect), height: min(height, width / aspect))
    }

    /// Where the desktop is drawn in the stage for a view (the picture layer's frame).
    static func drawn(stage: CGSize, aspect: CGFloat, view: ScreenView) -> CGRect {
        let fit = fitted(width: stage.width, height: stage.height, aspect: aspect)
        guard fit.width > 0 else { return .zero }
        let clamped = clampToDesktop(view, width: stage.width, height: stage.height, aspect: aspect)
        return CGRect(x: clamped.x + clamped.zoom * (stage.width - fit.width) / 2, y: clamped.y,
                      width: fit.width * clamped.zoom, height: fit.height * clamped.zoom)
    }

    /// Double-tap zoom: the level at which the fitted desktop fills the viewport, or 2.5× when it nearly does already.
    static func fillZoom(width: CGFloat, height: CGFloat, fitted: CGSize?) -> CGFloat {
        guard let fitted, fitted.width > 0, fitted.height > 0 else { return doubleTapZoom }
        let fill = max(width / fitted.width, height / fitted.height)
        return fill > 1.15 ? min(maxZoom, fill) : doubleTapZoom
    }

    /// Typing with the keyboard up on a short, wide stage (any phone on its side).
    static func compactTyping(typing: Bool, visible: CGSize?) -> Bool {
        guard typing, let visible, visible.width > 0, visible.height > 0 else { return false }
        return visible.height < 500 && visible.width > visible.height
    }

    /// The view that fills the stage's width with a desktop it letterboxes by height, the row last tapped (`fy`, a
    /// fraction of the desktop's height) in the middle; nil when the desktop already spans the width.
    static func fillWidthView(width: CGFloat, height: CGFloat, aspect: CGFloat, fy: CGFloat?) -> ScreenView? {
        guard aspect > 0, width > 0, height > 0 else { return nil }
        let zoom = min(maxZoom, width / min(width, height * aspect))
        guard zoom >= 1.05 else { return nil }
        let drawnHeight = min(height, width / aspect) * zoom
        return clampToDesktop(ScreenView(zoom: zoom, x: 0, y: height / 2 - (fy ?? 0.5) * drawnHeight), width: width, height: height, aspect: aspect)
    }

    /// Pan a zoomed view so a point (stage-local y) stays `margin` inside its bottom and top edges.
    static func keepVisible(_ view: ScreenView, pointY: CGFloat, width: CGFloat, height: CGFloat, margin: CGFloat = keepClear) -> ScreenView {
        let room = min(margin, height / 2)
        let shift = pointY > height - room ? height - room - pointY : (pointY < room ? room - pointY : 0)
        guard shift != 0 else { return view }
        var moved = view
        moved.y += shift
        return clampView(moved, width: width, height: height)
    }

    /// The rotate hint shows once, on a phone held upright.
    static func wantsRotateHint(seen: Bool, portrait: Bool, phone: Bool) -> Bool { phone && portrait && !seen }
}

/// The pointer of a controlled screen, kept as fractions of the desktop so zoom, rotation and letterboxing never move
/// it. It starts at the centre: the stream has no cursor-position messages.
nonisolated struct ScreenPointer: Equatable, Sendable {
    var x: CGFloat = 0.5
    var y: CGFloat = 0.5

    /// Moves by a finger's travel over a desktop drawn `drawn` points big, clamped to [0, 1 − 1/size].
    mutating func move(dx: CGFloat, dy: CGFloat, drawn: CGSize, framebuffer: (width: Int, height: Int)) {
        guard drawn.width > 0, drawn.height > 0 else { return }
        let maxX = framebuffer.width > 0 ? 1 - 1 / CGFloat(framebuffer.width) : 1 - 1 / drawn.width
        let maxY = framebuffer.height > 0 ? 1 - 1 / CGFloat(framebuffer.height) : 1 - 1 / drawn.height
        x = max(0, min(maxX, x + dx / drawn.width))
        y = max(0, min(maxY, y + dy / drawn.height))
    }

    /// The framebuffer pixel the pointer is on.
    func pixel(_ framebuffer: (width: Int, height: Int)) -> (x: Int, y: Int) {
        (max(0, min(framebuffer.width - 1, Int((x * CGFloat(framebuffer.width)).rounded()))),
         max(0, min(framebuffer.height - 1, Int((y * CGFloat(framebuffer.height)).rounded()))))
    }

    /// Where the pointer is in the stage, for a desktop drawn at `rect`.
    func point(in rect: CGRect) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
}

/// The touch rules as a state machine: feed it touches (stage-local points), it says what to do. One finger in
/// control mode is a relative trackpad (move, tap = click, hold = right click, hold then move = drag); two fingers
/// zoom the local view or, at fit size in control, scroll the remote screen; watching, one finger pans a zoomed view
/// and a double tap toggles fit and fill.
nonisolated struct ScreenGesture: Sendable {
    enum Action: Equatable, Sendable {
        /// The pointer moved (no button change): send its position, coalesced to one per display frame.
        case pointerMoved
        /// Send the pointer's position now, then this button mask (1 left, 4 right; 0 releases).
        case buttons(UInt8)
        /// A click: position, mask down, mask up.
        case click(UInt8)
        /// One wheel step (`down`: content moves up, as when fingers move up).
        case wheel(down: Bool)
        /// Show this view; `committed` false while fingers are still shaping it.
        case view(ScreenView, committed: Bool)
        /// The hold armed (550 ms without moving): a tick for the finger.
        case holdArmed
        /// A click landed at this fraction of the desktop.
        case tapped(CGFloat, CGFloat)
        /// A finger is down in control mode (the pointer ring shows) or lifted.
        case touching(Bool)
    }

    /// What the stage knows when a touch arrives.
    struct Context: Sendable {
        var control: Bool
        var stage: CGSize
        var aspect: CGFloat
        var framebuffer: (width: Int, height: Int)
    }

    private struct Pinch: Sendable {
        enum Mode: Sendable { case undecided, zoom, scroll }
        var distance: CGFloat
        var mid: CGPoint
        var base: ScreenView
        var next: ScreenView
        var mode: Mode = .undecided
        var scrolled: CGFloat = 0
    }

    private(set) var view = ScreenView.fit
    private(set) var pointer = ScreenPointer()
    /// The left button is held down (a drag).
    private(set) var pressed = false
    /// When a still finger's hold arms; nil when none is pending.
    private(set) var holdDeadline: TimeInterval?
    /// Where the last control tap landed, as fractions of the desktop.
    private(set) var tapped: (fx: CGFloat, fy: CGFloat)?

    private var start: CGPoint?
    private var last: CGPoint?
    private var didMove = false
    private var consumed = false
    private var armed = false
    private var pinch: Pinch?
    private var lastTap: (at: TimeInterval, point: CGPoint)?

    // MARK: View changes from outside

    mutating func setView(_ next: ScreenView, _ context: Context) {
        view = ScreenViewMath.clampToDesktop(next, width: context.stage.width, height: context.stage.height, aspect: context.aspect)
    }

    /// The stage changed size (rotation, keyboard): re-clamp, and keep the last tapped row clear of the edges.
    mutating func relayout(_ context: Context) {
        var next = ScreenViewMath.clampToDesktop(view, width: context.stage.width, height: context.stage.height, aspect: context.aspect)
        if next.zoom > 1, let tapped {
            let rect = ScreenViewMath.drawn(stage: context.stage, aspect: context.aspect, view: next)
            let pointY = rect.minY + tapped.fy * rect.height
            next = ScreenViewMath.clampToDesktop(ScreenViewMath.keepVisible(next, pointY: pointY, width: context.stage.width, height: context.stage.height),
                                                 width: context.stage.width, height: context.stage.height, aspect: context.aspect)
        }
        view = next
    }

    mutating func resetPointer() { pointer = ScreenPointer() }

    /// The framebuffer changed size: the pointer stays inside the new desktop.
    mutating func clampPointer(_ context: Context) {
        pointer.move(dx: 0, dy: 0, drawn: CGSize(width: 1, height: 1), framebuffer: context.framebuffer)
    }

    // MARK: Touches

    mutating func began(_ touches: [CGPoint], now: TimeInterval, _ context: Context) -> [Action] {
        var out: [Action] = []
        if touches.count >= 2 {
            holdDeadline = nil
            armed = false
            // A second finger ends a drag where it is.
            if pressed { pressed = false; out.append(.buttons(0)) }
            let a = touches[0], b = touches[1]
            pinch = Pinch(distance: max(1, hypot(a.x - b.x, a.y - b.y)), mid: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), base: view, next: view)
            consumed = true
            return out
        }
        guard let touch = touches.first else { return out }
        start = touch
        last = touch
        didMove = false
        consumed = false
        armed = false
        if context.control {
            holdDeadline = now + ScreenViewMath.longPress
            out.append(.touching(true))
        }
        return out
    }

    /// The hold timer: call when `holdDeadline` passes.
    mutating func holdFired(now: TimeInterval) -> [Action] {
        guard let deadline = holdDeadline, now >= deadline else { return [] }
        holdDeadline = nil
        guard !didMove, start != nil, !consumed else { return [] }
        armed = true
        return [.holdArmed]
    }

    mutating func moved(_ touches: [CGPoint], _ context: Context) -> [Action] {
        let width = context.stage.width, height = context.stage.height
        if var active = pinch, touches.count >= 2 {
            let a = touches[0], b = touches[1]
            let distance = max(1, hypot(a.x - b.x, a.y - b.y)), mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let factor = distance / active.distance
            if active.mode == .undecided {
                // At fit size in control a steady two-finger drag scrolls the remote screen; any real spread or
                // squeeze is a local zoom.
                if abs(factor - 1) > 0.08 { active.mode = .zoom } else if context.control, active.base.zoom == 1, abs(mid.y - active.mid.y) > ScreenViewMath.tapSlop { active.mode = .scroll }
            }
            var out: [Action] = []
            if active.mode == .scroll {
                active.scrolled += active.mid.y - mid.y
                active.mid = mid
                while abs(active.scrolled) >= ScreenViewMath.wheelTravel {
                    let down = active.scrolled > 0
                    out.append(.wheel(down: down))
                    active.scrolled -= (down ? 1 : -1) * ScreenViewMath.wheelTravel
                }
                pinch = active
                return out
            }
            let zoomed = ScreenViewMath.zoomAbout(active.base, factor: factor, at: active.mid, width: width, height: height)
            active.next = ScreenViewMath.clampToDesktop(ScreenView(zoom: zoomed.zoom, x: zoomed.x + (mid.x - active.mid.x), y: zoomed.y + (mid.y - active.mid.y)),
                                                        width: width, height: height, aspect: context.aspect)
            pinch = active
            return [.view(active.next, committed: false)]
        }
        guard let start, let last, !consumed, pinch == nil, let now = touches.first else { return [] }
        if !didMove, hypot(now.x - start.x, now.y - start.y) < ScreenViewMath.tapSlop { return [] }
        var out: [Action] = []
        if !didMove {
            didMove = true
            holdDeadline = nil
        }
        if context.control {
            if armed, !pressed {
                pressed = true
                out.append(.buttons(1))                 // the drag starts where the pointer is
            }
            let rect = ScreenViewMath.drawn(stage: context.stage, aspect: context.aspect, view: view)
            pointer.move(dx: now.x - last.x, dy: now.y - last.y, drawn: rect.size, framebuffer: context.framebuffer)
            out.append(.pointerMoved)
        } else if view.zoom > 1 {
            view = ScreenViewMath.clampToDesktop(ScreenView(zoom: view.zoom, x: view.x + now.x - last.x, y: view.y + now.y - last.y),
                                                 width: width, height: height, aspect: context.aspect)
            out.append(.view(view, committed: true))
        }
        self.last = now
        return out
    }

    /// `remaining`: how many fingers are still down.
    mutating func ended(remaining: Int, now: TimeInterval, _ context: Context) -> [Action] {
        var out: [Action] = []
        if let active = pinch {
            if remaining < 2 {
                if active.mode != .scroll {
                    view = active.next
                    out.append(.view(view, committed: true))
                }
                pinch = nil
            }
            if remaining == 0 { reset(); out.append(.touching(false)) }
            return out
        }
        guard remaining == 0 else { return out }
        holdDeadline = nil
        defer { reset() }
        if pressed {
            pressed = false
            tapped = (pointer.x, pointer.y)
            return [.buttons(0), .tapped(pointer.x, pointer.y), .touching(false)]
        }
        if !consumed, !didMove, let start {
            if context.control {
                tapped = (pointer.x, pointer.y)
                out += [.click(armed ? 4 : 1), .tapped(pointer.x, pointer.y)]
            } else if let earlier = lastTap, now - earlier.at < ScreenViewMath.doubleTap,
                      hypot(start.x - earlier.point.x, start.y - earlier.point.y) < ScreenViewMath.doubleTapReach {
                let width = context.stage.width, height = context.stage.height
                if view.zoom > 1 {
                    view = ScreenViewMath.clampToDesktop(.fit, width: width, height: height, aspect: context.aspect)
                } else {
                    let fit = ScreenViewMath.fitted(width: width, height: height, aspect: context.aspect)
                    let zoomed = ScreenViewMath.zoomAbout(view, factor: ScreenViewMath.fillZoom(width: width, height: height, fitted: fit), at: start, width: width, height: height)
                    view = ScreenViewMath.clampToDesktop(zoomed, width: width, height: height, aspect: context.aspect)
                }
                lastTap = nil
                out.append(.view(view, committed: true))
            } else {
                lastTap = (now, start)
            }
        }
        out.append(.touching(false))
        return out
    }

    /// An OS gesture or interruption cancelled the touch: end any drag where it is, never click.
    mutating func cancelled() -> [Action] {
        var out: [Action] = []
        if pressed { pressed = false; out.append(.buttons(0)) }
        if let active = pinch, active.mode != .scroll { out.append(.view(view, committed: true)) }
        pinch = nil
        holdDeadline = nil
        reset()
        out.append(.touching(false))
        return out
    }

    /// Control ended or the stream closed: forget any touch in flight. Returns whether a button was down (the caller
    /// releases it on the wire, DECISION D14).
    mutating func drop() -> Bool {
        let was = pressed
        pressed = false
        pinch = nil
        holdDeadline = nil
        reset()
        return was
    }

    private mutating func reset() {
        start = nil
        last = nil
        didMove = false
        consumed = false
        armed = false
    }
}
