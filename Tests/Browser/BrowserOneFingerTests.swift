// What one finger, or the mouse's button, sends to a held browser's page (HermesKit/Browser/BrowserTrackpadMath.swift).
// A tester (2026-11-16): drag and drop did nothing on the iPhone or the Mac; the press was never sent.

import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite struct BrowserOneFingerTests {
    typealias Out = BrowserOneFinger.Out

    // MARK: A finger on glass (the screen is a trackpad)

    @Test func aTapClicks() {
        var finger = BrowserOneFinger(kind: .trackpad)
        #expect(finger.lifted() == [.tap])
    }

    @Test func aFingerThatTravelsOnlyMovesThePointer() {
        var finger = BrowserOneFinger(kind: .trackpad)
        #expect(finger.travelled() == [])
        #expect(finger.held() == [], "a hold after the finger has travelled arms nothing")
        #expect(finger.travelled() == [])
        #expect(finger.lifted() == [], "no click, no button")
        #expect(!finger.buttonDown)
    }

    /// The report: hold, then drag. Holding presses right away (with a haptic tick and grab ring) so sliders and
    /// press-and-hold controls react before the finger moves; dragging keeps the button held and lifting lets go.
    @Test func aHoldThenATravelPressesDragsAndLetsGo() {
        var finger = BrowserOneFinger(kind: .trackpad)
        #expect(finger.held() == [.look(true), .haptic, .down])
        #expect(finger.buttonDown, "the hold presses immediately for sliders and press-and-hold controls")
        #expect(finger.held() == [], "pressing once")
        #expect(finger.travelled() == [], "already down: travel only moves the pointer")
        #expect(finger.buttonDown)
        #expect(finger.travelled() == [], "one press for the whole drag")
        #expect(finger.lifted() == [.up, .look(false)])
        #expect(!finger.buttonDown)
    }

    @Test func aHoldLiftedWithoutTravelIsAPressAndHold() {
        var finger = BrowserOneFinger(kind: .trackpad)
        #expect(finger.held() == [.look(true), .haptic, .down])
        #expect(finger.held() == [], "pressing once")
        #expect(finger.lifted() == [.up, .look(false)])
        #expect(!finger.buttonDown)
    }

    /// Double-tap-and-drag: a quick second touch near the prior tap arms a drag on movement, while lifting without
    /// moving still sends a normal tap so double-click to select a word works.
    @Test func aDoubleTapThenDragPressesAndLiftingWithoutTravelDoubleClicks() {
        var dragging = BrowserOneFinger(kind: .trackpad, armed: true)
        #expect(!dragging.buttonDown, "not pressed until travel or hold so a double-click still works")
        #expect(dragging.travelled() == [.look(true), .haptic, .down])
        #expect(dragging.buttonDown)
        #expect(dragging.held() == [], "already down")
        #expect(dragging.lifted() == [.up, .look(false)])
        #expect(!dragging.buttonDown)

        var doubleClick = BrowserOneFinger(kind: .trackpad, armed: true)
        #expect(doubleClick.lifted() == [.tap])

        var doubleTapHold = BrowserOneFinger(kind: .trackpad, armed: true)
        #expect(doubleTapHold.held() == [.look(true), .haptic, .down])
        #expect(doubleTapHold.lifted() == [.up, .look(false)])

        var cancelled = BrowserOneFinger(kind: .trackpad, armed: true)
        #expect(cancelled.cancelled() == [], "cancelled before pressing sent nothing")
    }

    @Test func doubleTapDragNeedsQuickAndNearbySecondTouch() {
        typealias M = BrowserTrackpadMath
        let prev = (time: 10.0, point: CGPoint(x: 200, y: 300))
        #expect(M.isDoubleTapDrag(previous: prev, at: CGPoint(x: 210, y: 305), now: 10.18))
        #expect(M.isDoubleTapDrag(previous: prev, at: CGPoint(x: 236, y: 300), now: 10.28))
        #expect(!M.isDoubleTapDrag(previous: prev, at: CGPoint(x: 200, y: 300), now: 10.35), "too slow: normal move")
        #expect(!M.isDoubleTapDrag(previous: prev, at: CGPoint(x: 260, y: 300), now: 10.15), "too far apart")
        #expect(!M.isDoubleTapDrag(previous: nil, at: CGPoint(x: 200, y: 300), now: 10.15))
    }

    @Test func aCancelledTouchLetsTheButtonGoAndNeverClicks() {
        var dragging = BrowserOneFinger(kind: .trackpad)
        _ = dragging.held()
        _ = dragging.travelled()
        #expect(dragging.cancelled() == [.up, .look(false)])
        #expect(dragging.cancelled() == [], "let go once")
        var heldStill = BrowserOneFinger(kind: .trackpad)
        _ = heldStill.held()
        #expect(heldStill.cancelled() == [.up, .look(false)])
        var plain = BrowserOneFinger(kind: .trackpad)
        #expect(plain.cancelled() == [])
    }

    // MARK: A mouse or a trackpad's pointer (the Mac, an iPad's)

    @Test func aMouseClickClicksAndAStillHoldPressesAndHolds() {
        var click = BrowserOneFinger(kind: .direct)
        #expect(click.lifted() == [.tap])

        var pressAndHold = BrowserOneFinger(kind: .direct)
        #expect(pressAndHold.held() == [.look(true), .down], "holding a mouse button still presses down with no haptic")
        #expect(pressAndHold.buttonDown)
        #expect(pressAndHold.held() == [])
        #expect(pressAndHold.lifted() == [.up, .look(false)])
        #expect(!pressAndHold.buttonDown)
    }

    @Test func aMousePressedAndMovedDragsAtOnce() {
        var mouse = BrowserOneFinger(kind: .direct)
        #expect(mouse.travelled() == [.look(true), .down])
        #expect(mouse.buttonDown)
        #expect(mouse.travelled() == [])
        #expect(mouse.lifted() == [.up, .look(false)])
        var cancelled = BrowserOneFinger(kind: .direct)
        _ = cancelled.travelled()
        #expect(cancelled.cancelled() == [.up, .look(false)])
        var still = BrowserOneFinger(kind: .direct)
        #expect(still.cancelled() == [], "a press taken away before it moved sent nothing")
    }

    // MARK: Where a pointer points

    @Test func aCursorOnThePageIsItsFractionAndBesideItTheNearestEdge() {
        typealias M = BrowserTrackpadMath
        // A 400 x 200 page drawn at (0, 100) in a 400 x 400 stage.
        let view = M.place(stage: CGSize(width: 400, height: 400), page: CGSize(width: 1200, height: 600), zoom: 1, x: 0, y: 0)
        #expect(view.frame == CGRect(x: 0, y: 100, width: 400, height: 200))
        #expect(M.clamped(CGPoint(x: 100, y: 150), in: view) == CGPoint(x: 0.25, y: 0.25))
        #expect(M.clamped(CGPoint(x: 100, y: 20), in: view) == CGPoint(x: 0.25, y: 0), "the margin above the page: its top edge")
        #expect(M.clamped(CGPoint(x: 500, y: 390), in: view) == CGPoint(x: 1, y: 1))
        #expect(M.fraction(CGPoint(x: 100, y: 20), in: view) == nil)
        #expect(M.clamped(CGPoint(x: 1, y: 1), in: M.View()) == nil, "no page yet")
        // Zoomed in twice about the top-left: the same cursor is half as far into the page.
        let zoomed = M.place(stage: CGSize(width: 400, height: 400), page: CGSize(width: 1200, height: 600), zoom: 2, x: 0, y: 0)
        #expect(M.clamped(CGPoint(x: 200, y: 100), in: zoomed) == CGPoint(x: 0.25, y: 0.25))
    }

    // MARK: Stage feedback & cursor alignment while pressed

    @MainActor private final class SpyHost: BrowserStageHost {
        var stageHasControl = true
        var sent: [BrowserInput] = []
        func stageSend(_ input: BrowserInput) { sent.append(input) }
        func stageWillTap() {}
        func stageZoomed() {}
        func stageWatchTap() {}
    }

    @MainActor private func makeStage() -> (BrowserStageView, SpyHost) {
        let stage = BrowserStageView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let host = SpyHost()
        stage.host = host
        let ctx = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        stage.show(ctx.makeImage()!, pageSize: CGSize(width: 1200, height: 600))
        stage.showsCursor = true
        return (stage, host)
    }

    @MainActor private func recordingHaptics(_ body: () -> Void) -> [Haptics.Kind] {
        let before = UserDefaults.standard.object(forKey: Haptics.key)
        let oldSink = Haptics.sink
        defer {
            Haptics.sink = oldSink
            if let before { UserDefaults.standard.set(before, forKey: Haptics.key) }
            else { UserDefaults.standard.removeObject(forKey: Haptics.key) }
        }
        UserDefaults.standard.removeObject(forKey: Haptics.key)
        var cues: [Haptics.Kind] = []
        Haptics.sink = { cues.append($0) }
        body()
        return cues
    }

    @MainActor @Test func stageHoldThenDragPlaysHapticShowsRingAlignsTipAndAvoidsWobbleJump() {
        let (stage, host) = makeStage()
        // Drawn rect is (0, 100, 400, 200); pointer starts at (0.5, 0.5) -> (200, 200).
        #expect(stage.debugCursorCenter == CGPoint(x: 200, y: 200))
        #expect(!stage.debugDragRingVisible)

        let cues = recordingHaptics {
            stage.debugTouchBegan(at: CGPoint(x: 100, y: 200), now: 1.0)
            // Small finger wobble within tapSlop before the hold fires.
            stage.debugTouchMoved(to: CGPoint(x: 105, y: 200))
            stage.debugHoldFired()
            #expect(stage.debugDragRingVisible)
            #expect(stage.debugCursorCenter == CGPoint(x: 200, y: 200))
            // First drag movement starts smoothly from (105, 200) -> +80x, -40y = (280, 160), no jump from pre-hold wobble.
            stage.debugTouchMoved(to: CGPoint(x: 185, y: 160))
            #expect(abs(stage.debugCursorCenter.x - 280) < 0.01)
            #expect(abs(stage.debugCursorCenter.y - 160) < 0.01)
            stage.debugTouchEnded(now: 1.8)
        }
        #expect(cues == [.selection])
        #expect(!stage.debugDragRingVisible)
        #expect(host.sent == [.down(x: 0.5, y: 0.5), .move(x: 0.7, y: 0.3), .up(x: 0.7, y: 0.3)])
    }

    @MainActor @Test func stageDoubleTapAndDragSendsDownMoveUpAndDoesNotReArmOnNextTouch() {
        let (stage, host) = makeStage()
        let cues = recordingHaptics {
            // First tap
            stage.debugTouchBegan(at: CGPoint(x: 100, y: 200), now: 10.0)
            stage.debugTouchEnded(now: 10.05)
            // Quick second touch nearby + drag
            stage.debugTouchBegan(at: CGPoint(x: 104, y: 202), now: 10.20)
            stage.debugTouchMoved(to: CGPoint(x: 144, y: 202))
            #expect(stage.debugDragRingVisible)
            stage.debugTouchEnded(now: 10.45)
            // Immediate third touch should move pointer normally, not drag
            stage.debugTouchBegan(at: CGPoint(x: 144, y: 202), now: 10.55)
            stage.debugTouchMoved(to: CGPoint(x: 184, y: 202))
            #expect(!stage.debugDragRingVisible)
            stage.debugTouchEnded(now: 10.70)
        }
        #expect(cues == [.selection])
        #expect(host.sent == [
            .tap(x: 0.5, y: 0.5),
            .down(x: 0.5, y: 0.5),
            .move(x: 0.6, y: 0.5),
            .up(x: 0.6, y: 0.5),
            .move(x: 0.7, y: 0.5),
        ])
    }

    @MainActor @Test func stageDoubleClickAndSlowOrFarFollowUpMovesNeverTriggerDrag() {
        let (stage, host) = makeStage()
        let cues = recordingHaptics {
            // Double-click (two quick taps without moving)
            stage.debugTouchBegan(at: CGPoint(x: 100, y: 200), now: 1.0)
            stage.debugTouchEnded(now: 1.05)
            stage.debugTouchBegan(at: CGPoint(x: 102, y: 201), now: 1.20)
            stage.debugTouchEnded(now: 1.25)
            // Slow follow-up move (> 0.28s): plain pointer move
            stage.debugTouchBegan(at: CGPoint(x: 102, y: 201), now: 1.70)
            stage.debugTouchMoved(to: CGPoint(x: 142, y: 201))
            stage.debugTouchEnded(now: 1.85)
            // Tap then immediate move far away (> 36pt): plain pointer move
            stage.debugTouchBegan(at: CGPoint(x: 50, y: 200), now: 3.0)
            stage.debugTouchEnded(now: 3.05)
            stage.debugTouchBegan(at: CGPoint(x: 200, y: 200), now: 3.15)
            stage.debugTouchMoved(to: CGPoint(x: 240, y: 200))
            stage.debugTouchEnded(now: 3.30)
        }
        #expect(cues.isEmpty)
        #expect(!host.sent.contains { if case .down = $0 { return true }; return false })
        #expect(host.sent == [
            .tap(x: 0.5, y: 0.5),
            .tap(x: 0.5, y: 0.5),
            .move(x: 0.6, y: 0.5),
            .tap(x: 0.6, y: 0.5),
            .move(x: 0.7, y: 0.5),
        ])
    }

    @MainActor @Test func stageCancellationLosingControlAndDirectPointerBehaveCleanly() {
        let (stage, host) = makeStage()
        // Cancel mid-drag releases the button and hides the ring
        stage.debugTouchBegan(at: CGPoint(x: 100, y: 200), now: 1.0)
        stage.debugHoldFired()
        stage.debugTouchMoved(to: CGPoint(x: 140, y: 200))
        stage.debugTouchCancelled()
        #expect(!stage.debugDragRingVisible)
        #expect(host.sent == [.down(x: 0.5, y: 0.5), .up(x: 0.6, y: 0.5)])

        // Losing control mid-hold clears visual state and ignores a late hold tick
        host.sent.removeAll()
        stage.debugTouchBegan(at: CGPoint(x: 100, y: 200), now: 2.0)
        host.stageHasControl = false
        stage.showsCursor = false
        stage.debugHoldFired()
        #expect(!stage.debugDragRingVisible)
        #expect(host.sent.isEmpty)

        // Direct pointer (Mac / iPad trackpad cursor) drags at once with tighter slop, no haptic, and keeps ring hidden
        host.stageHasControl = true
        stage.showsCursor = true
        let cues = recordingHaptics {
            stage.debugTouchBegan(at: CGPoint(x: 100, y: 150), points: true, now: 3.0)
            stage.debugTouchMoved(to: CGPoint(x: 105, y: 150))   // 5pt >= directDragSlop (4pt) starts dragging
            stage.debugTouchMoved(to: CGPoint(x: 200, y: 150))
            #expect(!stage.debugDragRingVisible, "hardware pointer uses its own system cursor")
            stage.debugTouchEnded(now: 3.2)

            // Press-and-hold on Mac (mouse held still >= 0.45s without moving) sends down then up
            stage.debugTouchBegan(at: CGPoint(x: 200, y: 150), points: true, now: 4.0)
            stage.debugHoldFired()
            #expect(!stage.debugDragRingVisible)
            stage.debugTouchEnded(now: 5.0)
        }
        #expect(cues.isEmpty)
        #expect(host.sent == [
            .move(x: 0.25, y: 0.25),
            .down(x: 0.25, y: 0.25),
            .move(x: 0.5, y: 0.25),
            .up(x: 0.5, y: 0.25),
            .down(x: 0.5, y: 0.25),
            .up(x: 0.5, y: 0.25),
        ])
    }
}
