// A-U1 (docs/spec/1x-voice.md §9): the memo gesture reducer, every case of W:src/ui-voice/memo-gesture.test.ts:21-178
// ported line for line (times in milliseconds, as the web's).

import Testing
@testable import HermesHQNative

@Suite("Memo gesture reducer (A-U1)")
struct MemoGestureTests {
    private static let on = true, off = false

    /// Runs inputs from `from`; returns the final state and every effect in order.
    private func run(_ inputs: [MemoInput], _ sendOnRelease: Bool = on, from: MemoGestureState = .idle)
        -> (state: MemoGestureState, effects: [MemoEffect]) {
        var state = from
        var effects: [MemoEffect] = []
        for input in inputs {
            let out = MemoGesture.reduce(state, input, sendOnRelease: sendOnRelease)
            state = out.state
            effects += out.effects
        }
        return (state, effects)
    }

    private let down = MemoInput.down(at: 1000, width: 402)
    private let started = MemoInput.started(at: 1080)

    /// The web's `types()`: an end effect's action, else the effect's kind.
    private func types(_ effects: [MemoEffect]) -> [String] {
        effects.map { effect in
            switch effect {
            case .end(let action): action.rawValue
            case .begin: "begin"
            case .sendReviewed: "send-reviewed"
            case .discardReviewed: "discard-reviewed"
            case .draftReviewed: "draft-reviewed"
            case .confirmDelete: "confirm-delete"
            case .tip: "tip"
            case .failed: "failed"
            case .haptic: "haptic"
            case .focusStatus: "focus-status"
            }
        }
    }

    @Test func touchDownAsksAtOnceAndIsNotRedUntilConfirmed() {
        let pressed = run([down])
        #expect(pressed.state.phase == .pressing)
        #expect(pressed.effects == [.begin])
        let recording = run([down, started])
        #expect(recording.state.phase == .holding)
        #expect(recording.state.startedAt == 1080)
    }

    @Test func permissionPromptRecordsNothingAndAllowTeaches() {
        let allowed = run([down, .up(at: 1300), .beginFailed(code: "permission-pending", granted: true)])
        #expect(allowed.state == .idle)
        #expect(allowed.effects == [.begin, .tip(.nowHold)])
        // A late "started" for that touch never begins recording.
        #expect(run([.started(at: 2000)], from: allowed.state).state == .idle)
        let denied = run([down, .beginFailed(code: "permission-pending", granted: false)])
        #expect(denied.effects.last == .failed(code: "permission-denied"))
        #expect(run([down, .beginFailed(code: "permission-denied")]).effects.last == .failed(code: "permission-denied"))
    }

    @Test func releaseBeforeOneSecondLocksStillRecording() {
        for at in [1001.0, 1200, 1000 + MemoGesture.holdSendMs - 1] {
            let (state, effects) = run([down, started, .up(at: at)])
            #expect(state.phase == .locked)
            #expect(state.tapLocked)
            #expect(!types(effects).contains("send"))
            #expect(!types(effects).contains("cancel"))
            #expect(effects.contains(.focusStatus))
        }
        // Moved a little (not to either line): still locked, but not a tap for the tip.
        let wobble = run([down, started, .move(dx: -30, dy: -10), .up(at: 1400)])
        #expect(wobble.state.phase == .locked)
        #expect(!wobble.state.tapLocked)
    }

    @Test func theSecondCountsFromRecordingStart() {
        // A Bluetooth headset or the busy-microphone retry: the recorder confirms 900 ms after the touch.
        let slow = run([down, .started(at: 1900), .up(at: 2100)])
        #expect(slow.state.phase == .locked)
        #expect(!types(slow.effects).contains("send"))
        // A full second of recording after that slow start sends as usual.
        #expect(run([down, .started(at: 1900), .up(at: 1900 + MemoGesture.holdSendMs)]).effects.last == .end(.send))
    }

    @Test func liftBeforeConfirmLocksOnceRecordingStarts() {
        let (state, _) = run([down, .up(at: 1050), started])
        #expect(state.phase == .locked)
        #expect(state.tapLocked)
    }

    @Test func releaseAtOneSecondOrLaterSends() {
        for at in [1080 + MemoGesture.holdSendMs, 9000] {
            let (state, effects) = run([down, started, .up(at: at)])
            #expect(state.phase == .ending)
            #expect(effects.last == .end(.send))
        }
        #expect(run([down, started, .up(at: 3000), .ended(action: .send)]).state == .idle)
    }

    @Test func sendOnReleaseOffStopsIntoReview() {
        let (state, effects) = run([down, started, .up(at: 3000)], Self.off)
        #expect(effects.last == .end(.review))
        let review = run([.ended(action: .review, seconds: 2)], Self.off, from: state)
        #expect(review.state.phase == .review)
        #expect(review.state.seconds == 2)
        #expect(run([.send], Self.off, from: review.state).effects == [.sendReviewed])
    }

    @Test func slidingLeftPastTheLineArmsCancel() {
        #expect(MemoGesture.cancelLine(402) == -120)
        #expect(MemoGesture.cancelLine(300) == -105)
        let armed = run([down, started, .move(dx: -125, dy: 0)])
        #expect(armed.state.cancelArmed)
        #expect(armed.effects.contains(.haptic(.cancelArmed)))
        #expect(run([.up(at: 5000)], from: armed.state).effects == [.end(.cancel)])
        // Sliding back disarms it: that release follows the time rule again.
        let back = run([.move(dx: -40, dy: 0), .up(at: 5000)], from: armed.state)
        #expect(back.effects.last == .end(.send))
        // Released past the line before the recorder confirmed: nothing is kept.
        #expect(run([down, .move(dx: -130, dy: 0), .up(at: 1100), started]).effects.last == .end(.cancel))
    }

    @Test func slidingUpLocks() {
        let near = run([down, started, .move(dx: 0, dy: -45)])
        #expect(near.state.lockNear)
        #expect(near.state.phase == .holding)
        let locked = run([.move(dx: 0, dy: MemoGesture.lockDY)], from: near.state)
        #expect(locked.state.phase == .locked)
        #expect(locked.effects.contains(.haptic(.lock)))
        // After locking, lifting the finger changes nothing.
        #expect(run([.up(at: 9000)], from: locked.state).state.phase == .locked)
    }

    @Test func pointerCancelKeepsADraft() {
        #expect(run([down, started, .pointerCancel]).effects.last == .end(.draft))
        // Before recording began, there is nothing to keep.
        #expect(run([down, .pointerCancel, started]).effects.last == .end(.cancel))
    }

    @Test func lockedRowStopSendAndReview() {
        let locked = run([down, started, .up(at: 1200)]).state
        #expect(run([.stop], from: locked).effects == [.end(.review)])
        #expect(run([.send], from: locked).effects == [.end(.send)])
        let review = run([.stop, .ended(action: .review, seconds: 4)], from: locked).state
        #expect(review.phase == .review)
        #expect(run([.delete], from: review).effects == [.discardReviewed])
    }

    @Test func deletingTenSecondsOrMoreAsksFirst() {
        let locked = run([down, started, .up(at: 1200), .tick(seconds: 45)]).state
        let asking = run([.delete], from: locked)
        #expect(asking.effects == [.confirmDelete(seconds: 45, recording: true)])
        #expect(asking.state.phase == .locked)
        #expect(!run([.deleteKept], from: asking.state).state.confirmingDelete)
        #expect(run([.deleteConfirmed], from: asking.state).effects == [.end(.cancel)])
        let short = run([down, started, .up(at: 1200), .tick(seconds: 9.9), .delete])
        #expect(short.effects.last == .end(.cancel))
    }

    @Test func limitFollowsTheReleaseRuleOrReviews() {
        let held = run([down, started])
        #expect(run([.limit(seconds: 600)], Self.on, from: held.state).effects == [.end(.send)])
        #expect(run([.limit(seconds: 600)], Self.off, from: held.state).effects == [.end(.review)])
        let locked = run([.up(at: 1100)], from: held.state)
        #expect(run([.limit(seconds: 600)], from: locked.state).effects == [.end(.review)])
        // A finger past the cancel line ("Release to Cancel") when the limit arrives cancels; it never sends.
        let armed = run([.move(dx: -125, dy: 0)], from: held.state)
        for option in [Self.on, Self.off] {
            #expect(run([.limit(seconds: 600)], option, from: armed.state).effects == [.end(.cancel)])
        }
    }

    @Test func nativeStopReturnsToIdle() {
        for from in [run([down, started]).state, run([down, started, .up(at: 1100)]).state] {
            let (state, effects) = run([.nativeStopped], from: from)
            #expect(state == .idle)
            #expect(effects.isEmpty)
        }
    }

    @Test func leavingKeepsADraftNeverSends() {
        #expect(run([down, started, .leave]).effects.last == .end(.draft))
        #expect(run([down, started, .up(at: 1100), .leave]).effects.last == .end(.draft))
        let review = run([down, started, .up(at: 1100), .stop, .ended(action: .review, seconds: 3)]).state
        let left = run([.leave], from: review)
        #expect(left.state == .idle)
        #expect(left.effects == [.draftReviewed])
        #expect(run([down, .leave, started]).effects.last == .end(.cancel))
    }

    @Test func voiceOverOpensTheLockedRecorder() {
        let (state, effects) = run([.a11yOpen(at: 1), started])
        #expect(state.phase == .locked)
        #expect(effects.contains(.focusStatus))
        #expect(!types(effects).contains("send"))
    }

    @Test func aSecondTouchIsIgnored() {
        let holding = run([down, started]).state
        let again = run([.down(at: 1500, width: 402)], from: holding)
        #expect(again.state == holding)
        #expect(again.effects.isEmpty)
    }

    /// The cancel line is min(120 pt, 35 % of the composer's width), never less than 0.35 pt (a zero width).
    @Test func cancelLineAtSmallWidths() {
        #expect(MemoGesture.cancelLine(0) == -0.35)
        #expect(MemoGesture.cancelLine(200) == -70)
    }
}
