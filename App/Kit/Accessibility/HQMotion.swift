// [a11y] One way to ask about motion and to animate (spec 3x-a11y §2.2). The rule is the web's
// (phone-transitions.ts:488-495, HermesUIChat.swift:105-110): under Reduce Motion nothing slides, scales, springs or
// glides. A thing that appears fades in over 0.2 s; a thing that moves is simply at its new place.

import SwiftUI
import UIKit

enum HQMotion {
    /// Reduce Motion (or the DEBUG `-HQA11yReduceMotion YES`). Safe from any thread.
    nonisolated static var reduced: Bool { HQAccessibility.reduceMotion }

    nonisolated static let fade: TimeInterval = 0.2

    /// [mac-feel] The shared scale for new motion: `quick` for a thing that swaps in place or fades (a place, a panel
    /// over the window), `pane` for an edge that travels (the inspector, a list folding away).
    nonisolated static let quick: TimeInterval = 0.12
    nonisolated static let pane: TimeInterval = 0.22

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

extension UIView {
    /// [mac-feel] A short fade-in of the view's own, for a thing that is put on screen in one step (a panel presented
    /// without the system's transition, the composer's drawer). Drawn on the layer, so it plays where UIKit has view
    /// animations switched off (during key input), and the view itself is at full alpha from the start: nothing waits
    /// for the fade and nothing can be left half shown. Opacity only; nothing under Reduce Motion.
    func hqFadeIn(_ duration: TimeInterval = HQMotion.quick) {
        guard !HQMotion.reduced else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = layer.opacity
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "hqFade")
    }

    /// [mac-feel] The matching fade-out; `done` runs when it ends (at once under Reduce Motion). The view is left at
    /// alpha 0: for a view that is about to be dismissed or removed.
    func hqFadeOut(_ duration: TimeInterval = HQMotion.quick, then done: @escaping () -> Void) {
        guard !HQMotion.reduced else { alpha = 0; return done() }
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(fade, forKey: "hqFade")
        UIView.performWithoutAnimation { alpha = 0 }
        CATransaction.commit()
    }
}
