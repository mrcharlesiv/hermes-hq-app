// [live] What a "reply finished" push (hermes-hq-push's `turnDone`, Shared/NotificationOpener.swift) means for the
// Lock Screen's progress: which turn it can end there and then, instead of waiting for the app to reopen or the
// 30-minute staleness rule (docs/spec/3x-presence.md §17.4). Pure rule, LiveKit's types only, so the unit tests check
// it without ActivityKit; NotificationService.swift calls ActivityKit with its answer (best effort: see there for
// what is, and isn't, known to work from an extension).
//
// `turnDone` fires once per completed, non-interrupted turn with a reply to show (hermes-hq-push's `turn_push`): there
// is no separate "failed" push, so this only ever says a turn can become Done, never Failed. A turn that errors out
// without a reply sends nothing — its activity is left to the 30-minute rule, as before this file existed.

import Foundation

nonisolated enum LiveActivityPush {
    /// `dispatch`, as `NotificationOpener.process` leaves it in the opened content's `userInfo["dispatch"]`. `nil`:
    /// this push says nothing about a Live Activity (not a finished turn, or no profile to match against
    /// `LiveActivitySubject.id` for `.turn`, which is the bot's profile — the same id the push already carries).
    static func turnFinished(_ dispatch: [String: Any]) -> LiveActivitySubject? {
        guard dispatch["kind"] as? String == "turnDone" else { return nil }
        guard let profile = dispatch["profile"] as? String, !profile.isEmpty else { return nil }
        return LiveActivitySubject(kind: .turn, id: profile)
    }
}
