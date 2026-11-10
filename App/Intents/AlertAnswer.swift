// An alert's answer, given exactly once: by one of its buttons, or as `unanswered` when the alert went away with no
// button tapped. A shortcut, a Home Screen quick action and a tapped notification all dismiss whatever is presented
// (docs/spec/3x-intents.md §14 S23), and an alert whose code awaits a button would then wait for ever: the push
// set-up offer stayed "running", so Settings › Notifications could not ask again until the app was relaunched.
//
// The alert's actions hold this object; when the alert is released (dismissed, or never shown because another
// presentation won), so is this, and whoever awaits gets `unanswered`.

import Foundation

final class AlertAnswer<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private let unanswered: Value

    init(_ continuation: CheckedContinuation<Value, Never>, unanswered: Value) {
        self.continuation = continuation
        self.unanswered = unanswered
    }

    func answer(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    deinit { continuation?.resume(returning: unanswered) }
}
