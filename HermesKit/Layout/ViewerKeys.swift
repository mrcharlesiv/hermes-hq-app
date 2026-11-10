// [mac] The mouse's and the keyboard's way into what a finger does by pinch and swipe in the viewers (Mac stress test
// round 2, #37 and #38): zoom steps for = / - / 0 and a scroll wheel (Watch Screen, Star Map), and ← / → across a
// message's photos. Pure values, unit tested in Tests/Kit/ViewerKeysTests.swift.

import CoreGraphics
import Foundation

/// A zoom key or button. ⌘= and ⌘− are the app's UI Scale (View menu), so the viewers take the keys unmodified.
nonisolated enum ZoomStep: Equatable, Sendable {
    case zoomIn, zoomOut, fit

    /// One press: the stage's and the map's VoiceOver Zoom in / Zoom out already step by this much.
    static let stepFactor: CGFloat = 1.5

    /// = (or +, Shift-=) zooms in, - (or _) zooms out, 0 fits.
    static func forKey(_ input: String) -> ZoomStep? {
        switch input {
        case "=", "+": .zoomIn
        case "-", "_": .zoomOut
        case "0": .fit
        default: nil
        }
    }

    /// The factor a step multiplies the zoom by; nil for Fit (each view knows its own fitted view).
    var factor: CGFloat? {
        switch self {
        case .zoomIn: Self.stepFactor
        case .zoomOut: 1 / Self.stepFactor
        case .fit: nil
        }
    }

    /// A scroll of `dy` points as a zoom factor: content pulled down (a wheel turned up) zooms in, as Maps does. A
    /// trackpad doubles the zoom every 200 pt of travel; a mouse wheel's notch (about 10 pt) is a fifth of a step
    /// more. One event never moves it more than a step either way.
    static func scrollFactor(_ dy: CGFloat, discrete: Bool) -> CGFloat {
        guard dy.isFinite, dy != 0 else { return 1 }
        let factor = pow(2, dy / (discrete ? 40 : 200))
        return min(stepFactor, max(1 / stepFactor, factor))
    }
}

/// ← and → in the photo viewers (and the Mac's previous / next buttons).
nonisolated enum PhotoPaging {
    /// The photo a step goes to, or nil at either end: it does not wrap round (the title reads "3 of 3").
    static func step(from index: Int, count: Int, forward: Bool) -> Int? {
        guard count > 1, (0..<count).contains(index) else { return nil }
        let next = index + (forward ? 1 : -1)
        return (0..<count).contains(next) ? next : nil
    }
}
