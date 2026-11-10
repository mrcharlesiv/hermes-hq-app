// Small value types shared by the memo recorder, the gesture reducer and the controller (spec 1x-voice §2.1).

import Foundation

/// What happens to a take when it ends (the web's `MemoEndAction`).
nonisolated enum MemoEndAction: String, Sendable, Equatable {
    case cancel, review, send, draft
}

/// Why the recorder stopped on its own (spec §3.3 step 4, §3.4).
nonisolated enum MemoStopReason: String, Sendable, Equatable {
    case interrupted
    case routeLost = "route-lost"
    case reset
    case background
    case error
    case limit
    case cancel
}

/// Why `begin` didn't start a recording (spec §3.3 step 1).
nonisolated enum MemoBeginError: Error, Sendable, Equatable {
    case busy
    case background
    /// The touch raised the permission prompt: it records nothing; `granted` is the answer.
    case permissionPending(granted: Bool)
    case permissionDenied
    case tooSmall
    case startFailed(String)
    case canceled

    /// The reducer's `begin-failed` code.
    var code: String {
        switch self {
        case .busy: "busy"
        case .background: "background"
        case .permissionPending: "permission-pending"
        case .permissionDenied: "permission-denied"
        case .tooSmall: "too-small"
        case .startFailed: "start-failed"
        case .canceled: "canceled"
        }
    }

    var granted: Bool? { if case .permissionPending(let g) = self { return g } else { return nil } }

    var message: String? {
        switch self {
        case .startFailed(let words): "Couldn’t start the voice memo: \(words)."
        case .tooSmall: "The attachment size limit is too small for a voice memo."
        default: nil
        }
    }
}

/// What the recorder did with a take it stopped by itself.
nonisolated enum MemoStopDisposition: Sendable, Equatable {
    /// The length limit: the reducer's `limit` rule decides (send, review or cancel).
    case await
    /// Saved as a draft chip in its chat.
    case draft(MemoFile)
    /// Under a second: nothing kept.
    case discard
    /// It couldn't be saved; the words say why.
    case failed(String)
}

/// The recorder's side of a take, delivered on the main actor.
nonisolated enum MemoCaptureEvent: Sendable, Equatable {
    /// 15 Hz: the current level (0…1) and the seconds recorded.
    case level(Double, seconds: Double)
    case stopped(reason: MemoStopReason, id: String, seconds: Double, disposition: MemoStopDisposition)
}

/// The two memo tips (spec §3.7).
nonisolated enum MemoTip: String, Sendable, Equatable {
    case nowHold = "now-hold"
    case holdToRecord = "hold-to-record"
    /// [talk] "Talk with <name>" on the circle (docs/spec/3x-talk.md §5.1).
    case talk
}

nonisolated enum MemoHaptic: Sendable, Equatable {
    case recording, lock, cancelArmed
}
