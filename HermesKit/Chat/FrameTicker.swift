// Coalesces model changes to at most one delivery per display frame (spec 04 §4.2: deltas flush ≥33 ms apart; the
// architecture note: at most one layout per frame). A paused CADisplayLink in the common run-loop mode, so it also
// fires while the user scrolls. `.manual` is for tests (call `fire()` yourself).

import QuartzCore
import UIKit

final class FrameTicker {
    enum Mode { case displayLink, manual }

    let mode: Mode
    private var link: CADisplayLink?
    private let action: () -> Void
    private(set) var isScheduled = false
    /// After `invalidate()` (the screen went away) nothing is scheduled — no display link is re-created by late task
    /// completions — until `revive()`.
    private(set) var isInvalidated = false

    init(mode: Mode, action: @escaping () -> Void) {
        self.mode = mode
        self.action = action
    }

    func schedule() {
        guard !isScheduled, !isInvalidated else { return }
        isScheduled = true
        guard mode == .displayLink else { return }
        if link == nil {
            let proxy = TickProxy()
            proxy.owner = self
            let l = CADisplayLink(target: proxy, selector: #selector(TickProxy.tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
    }

    /// Delivers now (tests, or before a synchronous read that must see everything).
    func fire() {
        link?.isPaused = true
        guard isScheduled else { return }
        isScheduled = false
        action()
    }

    func invalidate() {
        link?.invalidate()
        link = nil
        isScheduled = false
        isInvalidated = true
    }

    func revive() { isInvalidated = false }

    fileprivate func tick() { fire() }

    isolated deinit { link?.invalidate() }
}

private final class TickProxy: NSObject {
    weak var owner: FrameTicker?
    @objc func tick(_ link: CADisplayLink) {
        if let owner { owner.tick() } else { link.invalidate() }
    }
}
