// [a11y] One way to ask about motion and to animate (spec 3x-a11y §2.2). The rule is the web's
// (phone-transitions.ts:488-495, HermesUIChat.swift:105-110): under Reduce Motion nothing slides, scales, springs or
// glides. A thing that appears fades in over 0.2 s; a thing that moves is simply at its new place.

import SwiftUI
import UIKit

enum HQMotion {
    /// Reduce Motion (or the DEBUG `-HQA11yReduceMotion YES`). Safe from any thread.
    nonisolated static var reduced: Bool { HQAccessibility.reduceMotion }

    nonisolated static let fade: TimeInterval = 0.2

    /// [settings] Decorative loops (skeleton shimmer and pulse, idle heads) stop under Reduce Motion and while the
    /// phone saves power: Low Power Mode or heat (docs/spec/3x-settings.md §3; the web's `power-saver.css`).
    /// Transitions, typing dots, spinners and voice surfaces are not decoration: they keep asking `reduced`.
    /// A site that loops also listens for `PowerState.changed`, so it starts again when saving ends.
    static var decorativeStill: Bool { reduced || PowerState.shared.saving }

    /// Runs `changes` with the spring given; under Reduce Motion runs `reduced` (default: the same changes) at once,
    /// or in a 0.2 s cross-fade of `fading` when a view is given.
    static func spring(duration: TimeInterval = 0.4, damping: CGFloat = 0.82, velocity: CGFloat = 0, delay: TimeInterval = 0,
                       options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction],
                       fading: UIView? = nil, changes: @escaping () -> Void, reduced reducedChanges: (() -> Void)? = nil,
                       completion: ((Bool) -> Void)? = nil) {
        guard !reduced else { return settle(fading: fading, changes: reducedChanges ?? changes, completion: completion) }
        UIView.animate(withDuration: duration, delay: delay, usingSpringWithDamping: damping, initialSpringVelocity: velocity,
                       options: options, animations: changes, completion: completion)
    }

    /// The same for a plain curve.
    static func animate(_ duration: TimeInterval, delay: TimeInterval = 0,
                        options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction],
                        fading: UIView? = nil, changes: @escaping () -> Void, reduced reducedChanges: (() -> Void)? = nil,
                        completion: ((Bool) -> Void)? = nil) {
        guard !reduced else { return settle(fading: fading, changes: reducedChanges ?? changes, completion: completion) }
        UIView.animate(withDuration: duration, delay: delay, options: options, animations: changes, completion: completion)
    }

    private static func settle(fading: UIView?, changes: @escaping () -> Void, completion: ((Bool) -> Void)?) {
        if let fading {
            UIView.transition(with: fading, duration: fade, options: [.transitionCrossDissolve, .allowUserInteraction],
                              animations: { UIView.performWithoutAnimation(changes) }, completion: completion)
        } else {
            UIView.performWithoutAnimation(changes)
            completion?(true)
        }
    }

    /// SwiftUI: the animation to use for a change. `fades` says the change only shows or hides something (then it
    /// cross-fades in 0.2 s under Reduce Motion); anything that moves or resizes gets `nil` (at once).
    nonisolated static func swiftUI(_ animation: Animation?, fades: Bool = false) -> Animation? {
        guard reduced else { return animation }
        return fades ? .easeInOut(duration: fade) : nil
    }

    /// `withAnimation` that obeys the rule above.
    static func withAnimation<T>(_ animation: Animation? = .default, fades: Bool = false, _ body: () throws -> T) rethrows -> T {
        try SwiftUI.withAnimation(swiftUI(animation, fades: fades), body)
    }
}

extension AnyTransition {
    /// A transition that moves or scales, replaced by a plain fade under Reduce Motion.
    static func hqMotion(_ moving: AnyTransition) -> AnyTransition { HQMotion.reduced ? .opacity : moving }
}
