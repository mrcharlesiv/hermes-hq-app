// [offline] What counts as a return to the app (docs/spec/3x-offline.md §6.8), the native form of the web app's
// `src/focus-return.ts`. `sceneDidBecomeActive` fires after every moment the app was merely inactive (Control Center,
// the notification shade, a permission alert, the app switcher peeked and dismissed). Nobody was away then: the
// process ran throughout, its socket and timers with it, so nothing was missed and nothing is refreshed.
// **DECISION** (spec §6.8): however long the app sat inactive without entering the background, it is not a return.
// Pure.

import Foundation

nonisolated struct ReturnGate: Sendable {
    private var everActive = false
    private var wasInBackground = false
    private(set) var resignedAt: Date?

    init() {}

    mutating func resignedActive(at date: Date = Date()) { resignedAt = date }

    mutating func enteredBackground() { wasInBackground = true }

    /// True for the first activation after launch and for any activation after the app entered the background;
    /// false for an activation that follows only a resign-active.
    mutating func becameActive(at date: Date = Date()) -> Bool {
        defer { everActive = true; wasInBackground = false; resignedAt = nil }
        return !everActive || wasInBackground
    }
}
