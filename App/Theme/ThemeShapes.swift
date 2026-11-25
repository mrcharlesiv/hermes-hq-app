// desktoplook: shapes and metrics that change with the Desktop Look (spec 3x-desktoplook §3.5, §5.1). Look off:
// the value passed in, untouched.

import SwiftUI
import UIKit

nonisolated enum HQShape {
    enum Role { case inline, control, card, bubble, field, capsule, tile, group, sheet }

    /// The desktop's corners (phone-ui-desktop.css:59-66).
    static func desktopRadius(_ role: Role) -> CGFloat {
        switch role {
        case .inline: 2
        case .control, .tile: 3
        case .card, .bubble, .field, .capsule, .group: 4
        case .sheet: 8
        }
    }

    /// `standard` with the look off; the desktop's corner for the role with it on.
    static func radius(_ standard: CGFloat, _ role: Role) -> CGFloat {
        ThemeTable.current.state.desktopLook ? min(standard, desktopRadius(role)) : standard
    }

    /// List and sheet gutter: 20 pt in the Desktop Look (phone-ui-desktop.css:349-351).
    static func gutter(_ standard: CGFloat) -> CGFloat { ThemeTable.current.state.desktopLook ? 20 : standard }

    /// A 1 pt line: on the Mac, on whole screen pixels (`line`). iPhone and iPad: 1.
    static var hairline: CGFloat { line(1) }

    // MARK: Lines on whole pixels

    // [Mac AAA 2026-11-16] Feel list D33. The Mac draws the iPad layout at 77 %, so a line given in the app's points
    // lands between pixels: an iPhone hairline (1 / displayScale) came out at 0.39 px on a 1× display and 0.77 px on a
    // Retina one, a 1 pt line at 0.77 / 1.54 px; side by side they read as blurred and uneven. These two are the one
    // way to size a line: `pixel` is the thinnest sharp line (exactly one screen pixel), `line` any other width snapped
    // to whole pixels. The window is drawn straight into AppKit's backing store, so the pixels per point that count
    // are the screen's (`NSScreen.backingScaleFactor`), not UIKit's `displayScale`. iPhone and iPad: unchanged.

    /// One screen pixel in the app's points: replaces `1 / max(1, traitCollection.displayScale)`. `scale`: the view's
    /// `displayScale` (what the iPhone and the iPad use; the Mac reads its screen).
    static func pixel(_ scale: CGFloat) -> CGFloat {
        #if targetEnvironment(macCatalyst)
        return 1 / (MacTypeSteps.catalyst * macBacking)
        #else
        return 1 / max(1, scale)
        #endif
    }

    /// A line `points` wide (the app's points), on the Mac rounded to whole screen pixels and never under one.
    static func line(_ points: CGFloat) -> CGFloat {
        #if targetEnvironment(macCatalyst)
        guard points > 0 else { return 0 }
        let perPoint = MacTypeSteps.catalyst * macBacking
        return max(1, (points * perPoint).rounded()) / perPoint
        #else
        return points
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// [Mac AAA 2026-11-16] How far to move a line whose edge is at `at` (window points) so it starts on a whole screen
    /// pixel: a point position lands at `at × 0.77 × backing` screen pixels, so a one-pixel line placed on UIKit's own
    /// grid (0.5 pt) mostly straddled two pixel rows and drew as a soft grey pair (Status & Maintenance's cards).
    static func pixelNudge(_ at: CGFloat) -> CGFloat {
        let perPoint = MacTypeSteps.catalyst * macBacking
        let pixels = at * perPoint
        return (pixels.rounded() - pixels) / perPoint
    }

    /// Screen pixels per Mac point where the app's key window is (1 on a 1080p display, 2 on a Retina one).
    /// With no key window (at launch, or while another app is in front) `mainScreen` can be nil: the first screen
    /// answers then, so a line is not drawn for the wrong kind of display.
    static var macBacking: CGFloat {
        let screens = NSClassFromString("NSScreen") as? NSObject.Type
        let screen = (screens?.value(forKey: "mainScreen") as? NSObject) ?? (screens?.value(forKey: "screens") as? [NSObject])?.first
        let scale = (screen?.value(forKey: "backingScaleFactor") as? NSNumber).map { CGFloat($0.doubleValue) } ?? 2
        return max(1, scale)
    }
    #endif

    /// The time under a message: replies only in the Desktop Look (phone-ui-desktop.css: your own box has none). The
    /// layout asks, so no room is kept for a time that is not drawn.
    static func showsTime(mine: Bool) -> Bool { !(mine && ThemeTable.current.state.desktopLook) }

    /// A reply in the Desktop Look has no bubble: its text sits on the page margin, with no padding kept for a bubble
    /// that is not drawn and no face column beside it (owner, 2026-10-14: the reply looked indented). High Contrast
    /// boxes it like your own message (owner, 2026-10-26) unless Chat Bubbles › Reply Bubbles is off, so it keeps the
    /// bubble's padding only then. [plain-replies] In the iOS look, when Chat Bubbles › Reply Bubbles is off (owner 2026-11-15).
    static var plainReplies: Bool { ThemeTable.current.state.appliedPlainReplies }
}

/// [Mac AAA 2026-11-16] A pill: iOS's capsule with the look off; the Desktop Look's 4 pt box with it on (its brand is
/// square corners: round chips in it, as Marketplace's Install, read as borrowed from the iPhone).
nonisolated struct HQPill: InsettableShape {
    var desktop = ThemeTable.current.state.desktopLook
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        return desktop
            ? RoundedRectangle(cornerRadius: HQShape.desktopRadius(.capsule), style: .continuous).path(in: box)
            : Capsule().path(in: box)
    }

    func inset(by amount: CGFloat) -> HQPill {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// [Mac AAA 2026-11-16] The app's one SwiftUI hairline: `HQShape.hairline` thick (one screen pixel on the Mac) and, on
/// the Mac, moved by under a pixel to where its edge lands on a whole screen pixel given where it really is in the
/// window. A line only one pixel wide that SwiftUI placed on the point grid still smeared over two pixel rows (R9).
/// `length`: a fixed length along the line (nil: what it is offered). `-HQDebugHairlines YES` (DEBUG) writes each
/// line's screen-pixel edge to the app's log. iPhone and iPad: the plain rectangle.
struct HQHairline: View {
    var axis: Axis = .horizontal
    var color = Color(uiColor: HQPalette.separator)
    var length: CGFloat?

    var body: some View {
        let width = axis == .vertical ? HQShape.hairline : length
        let height = axis == .horizontal ? HQShape.hairline : length
        #if targetEnvironment(macCatalyst)
        // The line is drawn inside a reader of its own place, moved there and then, with no state: a nudge kept in
        // state re-rendered the view, and in the Desktop Look's segment strip at 150 % that fed back into the strip's
        // own sizing and never settled.
        Color.clear
            .frame(width: width, height: height)
            .overlay {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .global)
                    let at = axis == .horizontal ? frame.minY : frame.minX
                    let nudge = HQShape.pixelNudge(at)
                    #if DEBUG
                    let _ = HQHairline.note(axis: axis, at: at, nudge: nudge)
                    #endif
                    Rectangle().fill(color)
                        .offset(x: axis == .vertical ? nudge : 0, y: axis == .horizontal ? nudge : 0)
                }
            }
            .accessibilityHidden(true)
        #else
        Rectangle().fill(color).frame(width: width, height: height).accessibilityHidden(true)
        #endif
    }

    #if DEBUG && targetEnvironment(macCatalyst)
    /// `-HQDebugHairlines YES`: each line's screen-pixel edge in the app's log (it must be whole, ± 0.01).
    static func note(axis: Axis, at: CGFloat, nudge: CGFloat) {
        guard UserDefaults.standard.bool(forKey: "HQDebugHairlines") else { return }
        let pixels = (at + nudge) * MacTypeSteps.catalyst * HQShape.macBacking
        let off = abs(pixels - pixels.rounded())
        AppLog.note("mac", String(format: "hairline %@ at %.3f pt → screen px %.3f (%@)", axis == .horizontal ? "y" : "x",
                                  at, pixels, off <= 0.01 ? "whole" : "OFF GRID"))
    }
    #endif
}
