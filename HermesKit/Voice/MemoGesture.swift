// The one-gesture voice memo: a pure reducer, a line-for-line port of W:src/ui-voice/memo-gesture.ts:80-166 (spec
// 1x-voice §3.2; owner decision 1: it sends on release). Touches and recorder answers in, a state and the effects to
// run out; `MemoController` runs the effects.
//
//   touch-down                 → begin at once; red only once the recorder says it is recording
//   permission prompt          → nothing records; after Allow, the "Now Hold to Record" tip
//   release before 1.0 s       → locked, hands-free, still recording (never sends, never discards)
//   release at 1.0 s or later  → sends (Send Memo on Release, the default), else stops into review
//                                (the second counts from when recording started, not from the touch)
//   slide left past the line   → cancel;  slide up to −72 pt → locked
//   pointer cancelled          → kept as a draft chip, never sent
//
// Times are milliseconds (as the web's), so the 1.0 s rule compares whole numbers exactly.

import Foundation

nonisolated enum MemoPhase: String, Sendable, Equatable {
    case idle, pressing, holding, locked, ending, review
}

nonisolated struct MemoGestureState: Sendable, Equatable {
    var phase: MemoPhase = .idle
    var downAt: Double = 0
    var startedAt: Double? = nil
    var width: Double = 0
    var dx: Double = 0
    var dy: Double = 0
    /// The finger left before the recorder confirmed the recording.
    var released = false
    /// The system took the touch (a call banner, an alert) before the recorder confirmed.
    var canceled = false
    var cancelArmed = false
    var lockNear = false
    /// Locked by a short touch (the "Hold to Record" tip teaches the gesture after the first one).
    var tapLocked = false
    var confirmingDelete = false
    /// The take's length: live while recording, final in review.
    var seconds: Double = 0
    var ending: MemoEndAction? = nil

    static let idle = MemoGestureState()

    var isRecording: Bool { phase == .holding || phase == .locked }
}

nonisolated enum MemoInput: Sendable, Equatable {
    case down(at: Double, width: Double)
    case a11yOpen(at: Double)
    case move(dx: Double, dy: Double)
    case up(at: Double)
    case pointerCancel
    case started(at: Double)
    case beginFailed(code: String, granted: Bool? = nil, message: String? = nil)
    case tick(seconds: Double)
    case stop
    case send
    case delete
    case deleteConfirmed
    case deleteKept
    case limit(seconds: Double)
    case nativeStopped
    case leave
    case ended(action: MemoEndAction, seconds: Double? = nil)
    case reset
}

nonisolated enum MemoEffect: Sendable, Equatable {
    case begin
    case end(MemoEndAction)
    case sendReviewed
    case discardReviewed
    case draftReviewed
    case confirmDelete(seconds: Double, recording: Bool)
    case tip(MemoTip)
    case failed(code: String, message: String? = nil)
    case haptic(MemoHaptic)
    case focusStatus
}

nonisolated enum MemoGesture {
    static let holdSendMs: Double = 1000
    static let tapSlop: Double = 12
    static let lockDY: Double = -72
    static let lockNearDY: Double = -40
    static let deleteConfirmSeconds: Double = 10

    /// How far left cancels: min(120 pt, 35 % of the composer's width).
    static func cancelLine(_ width: Double) -> Double { -min(120, max(1, width) * 0.35) }

    private static func moved(_ s: MemoGestureState) -> Bool { (s.dx * s.dx + s.dy * s.dy).squareRoot() >= tapSlop }

    static func reduce(_ state: MemoGestureState, _ input: MemoInput, sendOnRelease: Bool)
        -> (state: MemoGestureState, effects: [MemoEffect]) {
        func next(_ patch: (inout MemoGestureState) -> Void, _ effects: MemoEffect...) -> (MemoGestureState, [MemoEffect]) {
            var s = state
            patch(&s)
            return (s, effects)
        }
        func end(_ action: MemoEndAction, _ patch: (inout MemoGestureState) -> Void = { _ in }) -> (MemoGestureState, [MemoEffect]) {
            var s = state
            patch(&s)
            s.phase = .ending
            s.ending = action
            s.cancelArmed = false
            s.confirmingDelete = false
            return (s, [.end(action)])
        }
        func lock(_ patch: (inout MemoGestureState) -> Void = { _ in }) -> (MemoGestureState, [MemoEffect]) {
            var s = state
            patch(&s)
            s.phase = .locked
            s.cancelArmed = false
            s.lockNear = false
            return (s, [.haptic(.lock), .focusStatus])
        }
        let unchanged = (state, [MemoEffect]())

        switch input {
        case .reset:
            return (.idle, [])
        case .down(let at, let width):
            guard state.phase == .idle else { return unchanged }
            var s = MemoGestureState.idle
            s.phase = .pressing
            s.downAt = at
            s.width = width
            return (s, [.begin])
        case .a11yOpen(let at):
            // VoiceOver's double-tap and Voice Control's "Tap": the locked recorder, never a hold.
            guard state.phase == .idle else { return unchanged }
            var s = MemoGestureState.idle
            s.phase = .pressing
            s.downAt = at
            s.released = true
            s.tapLocked = false
            return (s, [.begin])
        case .move(let dx, let dy):
            guard state.phase == .pressing || state.phase == .holding else { return unchanged }
            let armed = dx <= cancelLine(state.width)
            let patch: (inout MemoGestureState) -> Void = { s in
                s.dx = dx; s.dy = dy; s.cancelArmed = armed; s.lockNear = dy <= lockNearDY
            }
            if state.phase == .holding && dy <= lockDY && !armed { return lock(patch) }
            if armed && !state.cancelArmed && state.phase == .holding { return next(patch, .haptic(.cancelArmed)) }
            return next(patch)
        case .up(let at):
            if state.phase == .pressing { return next { $0.released = true } }
            guard state.phase == .holding else { return unchanged }
            if state.cancelArmed { return end(.cancel) }
            // A short or unsure touch never sends and never loses audio: it keeps recording hands-free.
            if at - (state.startedAt ?? state.downAt) < holdSendMs {
                let tap = !moved(state)
                return lock { $0.tapLocked = tap }
            }
            return end(sendOnRelease ? .send : .review)
        case .pointerCancel:
            if state.phase == .pressing { return next { $0.canceled = true } }
            if state.phase == .holding { return end(.draft) }
            return unchanged
        case .started(let at):
            guard state.phase == .pressing else { return unchanged }
            if state.canceled || (state.released && state.cancelArmed) { return end(.cancel) { $0.startedAt = at } }
            // Let go before the recorder confirmed: nothing was recorded while the finger was down, so however long
            // the touch was there is no take to send; it records hands-free from now.
            if state.released {
                let tap = !moved(state)
                return lock { $0.startedAt = at; $0.tapLocked = tap }
            }
            if state.dy <= lockDY && !state.cancelArmed { return lock { $0.startedAt = at } }
            return next({ $0.phase = .holding; $0.startedAt = at }, .haptic(.recording))
        case .beginFailed(let code, let granted, let message):
            guard state.phase == .pressing else { return unchanged }
            if code == "permission-pending" {
                return (.idle, [granted == true ? .tip(.nowHold) : .failed(code: "permission-denied")])
            }
            if code == "busy" || code == "canceled" { return (.idle, []) }
            return (.idle, [.failed(code: code, message: message)])
        case .tick(let seconds):
            return state.isRecording ? next { $0.seconds = seconds } : unchanged
        case .stop:
            return state.phase == .locked ? end(.review) : unchanged
        case .send:
            if state.phase == .locked { return end(.send) }
            if state.phase == .review { return (.idle, [.sendReviewed]) }
            return unchanged
        case .delete:
            guard state.phase == .locked || state.phase == .review else { return unchanged }
            if state.seconds >= deleteConfirmSeconds {
                return next({ $0.confirmingDelete = true }, .confirmDelete(seconds: state.seconds, recording: state.phase == .locked))
            }
            return state.phase == .locked ? end(.cancel) : (.idle, [.discardReviewed])
        case .deleteConfirmed:
            guard state.confirmingDelete else { return unchanged }
            return state.phase == .locked ? end(.cancel) : (.idle, [.discardReviewed])
        case .deleteKept:
            return next { $0.confirmingDelete = false }
        case .limit(let seconds):
            // At the limit the recording has already stopped: a held memo follows the release rule (a finger past the
            // cancel line, showing "Release to Cancel", cancels), a locked one goes to review.
            if state.phase == .holding {
                return state.cancelArmed ? end(.cancel) { $0.seconds = seconds }
                    : end(sendOnRelease ? .send : .review) { $0.seconds = seconds }
            }
            if state.phase == .locked { return end(.review) { $0.seconds = seconds } }
            return unchanged
        case .nativeStopped:
            // A call, Siri, leaving the app: the recorder kept the take as a draft (or dropped a sub-second one).
            return state.isRecording || state.phase == .pressing ? (.idle, []) : unchanged
        case .leave:
            // Its chat left the screen: a take left behind becomes a draft chip in the chat it started in (C3).
            if state.phase == .pressing { return next { $0.canceled = true } }
            if state.isRecording { return end(.draft) }
            if state.phase == .review { return (.idle, [.draftReviewed]) }
            return unchanged
        case .ended(let action, let seconds):
            guard state.phase == .ending else { return unchanged }
            if action == .review {
                return next { $0.phase = .review; $0.ending = nil; $0.seconds = seconds ?? state.seconds }
            }
            return (.idle, [])
        }
    }
}
