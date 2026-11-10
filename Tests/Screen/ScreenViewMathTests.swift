// The Screen's view math and touch rules (docs/spec/3x-screen.md §5.5, §5.7), ported from the web app's
// bot-screen-phone.test.ts so the numbers are the same on both.

import CoreGraphics
import Foundation
import Testing
@testable import HermesHQNative

private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.001) -> Bool { abs(a - b) <= tolerance }

@MainActor struct ScreenViewMathTests {
    @Test func clampsAndZoomsAboutAPoint() {
        #expect(ScreenViewMath.clampView(ScreenView(zoom: 9, x: 50, y: -5000), width: 400, height: 250) == ScreenView(zoom: 5, x: 0, y: -1000))
        let zoomed = ScreenViewMath.zoomAbout(.fit, factor: 2, at: CGPoint(x: 200, y: 125), width: 400, height: 250)
        #expect(zoomed == ScreenView(zoom: 2, x: -200, y: -125))
        #expect(ScreenViewMath.zoomAbout(zoomed, factor: 0.1, at: .zero, width: 400, height: 250) == .fit)
    }

    @Test func clampsToTheDrawnDesktopNotTheLetterbox() {
        let aspect: CGFloat = 1024.0 / 640.0
        #expect(ScreenViewMath.clampToDesktop(.fit, width: 402, height: 600, aspect: aspect) == ScreenView(zoom: 1, x: 0, y: (600 - 251.25) / 2))
        #expect(ScreenViewMath.clampToDesktop(ScreenView(zoom: 2, x: -900, y: -300), width: 402, height: 600, aspect: aspect) == ScreenView(zoom: 2, x: -402, y: (600 - 502.5) / 2))
        #expect(close(ScreenViewMath.clampToDesktop(.fit, width: 574, height: 1013, aspect: aspect).y, (1013 - 358.75) / 2))
        #expect(ScreenViewMath.clampToDesktop(ScreenView(zoom: 3, x: 0, y: -2000), width: 402, height: 600, aspect: aspect) == ScreenView(zoom: 3, x: 0, y: 600 - 402 / aspect * 3))
        let landscape = ScreenViewMath.clampToDesktop(ScreenView(zoom: 1.2, x: -50, y: 0), width: 874, height: 330, aspect: aspect)
        #expect(close(landscape.x, (874 - 528 * 1.2) / 2 - (874 * 1.2 - 528 * 1.2) / 2))
        let plain = ScreenView(zoom: 2, x: 0, y: 0)
        #expect(ScreenViewMath.clampToDesktop(plain, width: 400, height: 250, aspect: 0) == ScreenViewMath.clampView(plain, width: 400, height: 250))
    }

    @Test func theDesktopIsDrawnCentredAcrossAndNeverInTheBands() {
        let aspect: CGFloat = 1024.0 / 640.0
        // Portrait: full width, centred down.
        let portrait = ScreenViewMath.drawn(stage: CGSize(width: 402, height: 600), aspect: aspect, view: .fit)
        #expect(close(portrait.minX, 0) && close(portrait.width, 402) && close(portrait.height, 251.25) && close(portrait.minY, 174.375))
        // Landscape: full height, centred across.
        let landscape = ScreenViewMath.drawn(stage: CGSize(width: 874, height: 330), aspect: aspect, view: .fit)
        #expect(close(landscape.width, 528) && close(landscape.height, 330) && close(landscape.minX, 173) && close(landscape.minY, 0))
        // Zoomed in landscape until wider than the stage: the left edge can reach the stage's edge, never past it.
        let wide = ScreenViewMath.drawn(stage: CGSize(width: 874, height: 330), aspect: aspect, view: ScreenView(zoom: 3, x: 5000, y: 5000))
        #expect(close(wide.minX, 0) && close(wide.minY, 0) && close(wide.width, 1584))
        let far = ScreenViewMath.drawn(stage: CGSize(width: 874, height: 330), aspect: aspect, view: ScreenView(zoom: 3, x: -5000, y: -5000))
        #expect(close(far.maxX, 874) && close(far.maxY, 330))
        #expect(ScreenViewMath.drawn(stage: .zero, aspect: aspect, view: .fit) == .zero)
        #expect(ScreenViewMath.drawn(stage: CGSize(width: 10, height: 10), aspect: 0, view: .fit) == .zero)
    }

    @Test func doubleTapFillsTheScreen() {
        #expect(close(ScreenViewMath.fillZoom(width: 402, height: 600, fitted: CGSize(width: 402, height: 251)), 600.0 / 251.0))
        #expect(close(ScreenViewMath.fillZoom(width: 874, height: 330, fitted: CGSize(width: 528, height: 330)), 874.0 / 528.0))
        #expect(ScreenViewMath.fillZoom(width: 400, height: 250, fitted: CGSize(width: 400, height: 250)) == 2.5)
        #expect(ScreenViewMath.fillZoom(width: 400, height: 250, fitted: nil) == 2.5)
        #expect(ScreenViewMath.fillZoom(width: 4000, height: 250, fitted: CGSize(width: 40, height: 25)) == 5)
    }

    @Test func keepsTheTappedPointClearOfTheKeyBar() {
        #expect(ScreenViewMath.keepVisible(ScreenView(zoom: 2, x: 0, y: 0), pointY: 300, width: 400, height: 330) == ScreenView(zoom: 2, x: 0, y: -10))
        #expect(ScreenViewMath.keepVisible(ScreenView(zoom: 2, x: 0, y: -200), pointY: 20, width: 400, height: 330) == ScreenView(zoom: 2, x: 0, y: -180))
        let view = ScreenView(zoom: 2, x: 0, y: 0)
        #expect(ScreenViewMath.keepVisible(view, pointY: 100, width: 400, height: 330) == view)
    }

    @Test func typingOnAShortWideScreenFillsTheWidth() throws {
        #expect(ScreenViewMath.compactTyping(typing: true, visible: CGSize(width: 1194, height: 406)))
        #expect(ScreenViewMath.compactTyping(typing: true, visible: CGSize(width: 874, height: 150)))
        #expect(!ScreenViewMath.compactTyping(typing: true, visible: CGSize(width: 834, height: 790)))
        #expect(!ScreenViewMath.compactTyping(typing: true, visible: CGSize(width: 375, height: 400)))
        #expect(!ScreenViewMath.compactTyping(typing: false, visible: CGSize(width: 1194, height: 406)))
        #expect(!ScreenViewMath.compactTyping(typing: true, visible: nil))
        let aspect: CGFloat = 1024.0 / 640.0
        let filled = try #require(ScreenViewMath.fillWidthView(width: 922, height: 314, aspect: aspect, fy: 0.5))
        #expect(close(filled.zoom, 922 / (314 * aspect)))
        #expect(close(filled.y, 314 / 2 - 0.5 * 922 / aspect))
        #expect(close(try #require(ScreenViewMath.fillWidthView(width: 922, height: 314, aspect: aspect, fy: 1)).y, 314 - 922 / aspect))
        #expect(try #require(ScreenViewMath.fillWidthView(width: 922, height: 314, aspect: aspect, fy: 0)).y == 0)
        #expect(ScreenViewMath.fillWidthView(width: 402, height: 600, aspect: aspect, fy: 0.5) == nil)
        #expect(ScreenViewMath.fillWidthView(width: 874, height: 60, aspect: aspect, fy: 0.5)?.zoom == 5)
        #expect(ScreenViewMath.fillWidthView(width: 922, height: 314, aspect: 0, fy: 0.5) == nil)
        // The filled desktop spans the stage's width exactly.
        let drawn = ScreenViewMath.drawn(stage: CGSize(width: 922, height: 314), aspect: aspect, view: filled)
        #expect(close(drawn.minX, 0) && close(drawn.width, 922))
    }

    @Test func theRotateHintShowsOnceOnAPhoneHeldUpright() {
        #expect(ScreenViewMath.wantsRotateHint(seen: false, portrait: true, phone: true))
        #expect(!ScreenViewMath.wantsRotateHint(seen: true, portrait: true, phone: true))
        #expect(!ScreenViewMath.wantsRotateHint(seen: false, portrait: false, phone: true))
        #expect(!ScreenViewMath.wantsRotateHint(seen: false, portrait: true, phone: false))
    }

    @Test func thePointerIsAFractionOfTheDesktopAndStaysInside() {
        var pointer = ScreenPointer()
        #expect(pointer.pixel((1280, 800)) == (640, 400))
        pointer.move(dx: 36, dy: -18, drawn: CGSize(width: 360, height: 180), framebuffer: (1200, 600))
        #expect(close(pointer.x, 0.6) && close(pointer.y, 0.4))
        #expect(pointer.pixel((1200, 600)) == (720, 240))
        pointer.move(dx: 9000, dy: 9000, drawn: CGSize(width: 360, height: 180), framebuffer: (1200, 600))
        #expect(pointer.pixel((1200, 600)) == (1199, 599))
        pointer.move(dx: -90000, dy: -90000, drawn: CGSize(width: 360, height: 180), framebuffer: (1200, 600))
        #expect(pointer.pixel((1200, 600)) == (0, 0))
        // No picture yet: nothing moves, nothing divides by zero.
        pointer.move(dx: 10, dy: 10, drawn: .zero, framebuffer: (0, 0))
        #expect(pointer == ScreenPointer(x: 0, y: 0))
        #expect(ScreenPointer(x: 0.25, y: 0.5).point(in: CGRect(x: 20, y: 120, width: 360, height: 180)) == CGPoint(x: 110, y: 210))
    }
}

@MainActor struct ScreenGestureTests {
    private func context(control: Bool, stage: CGSize = CGSize(width: 400, height: 250), framebuffer: (Int, Int) = (400, 250)) -> ScreenGesture.Context {
        ScreenGesture.Context(control: control, stage: stage, aspect: CGFloat(framebuffer.0) / CGFloat(framebuffer.1), framebuffer: framebuffer)
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    @Test func aTapClicksAtThePointerNotAtTheFinger() {
        var gesture = ScreenGesture()
        let control = context(control: true)
        #expect(gesture.began([p(40, 60)], now: 0, control) == [.touching(true)])
        #expect(gesture.holdDeadline == 0.55)
        #expect(gesture.ended(remaining: 0, now: 0.1, control) == [.click(1), .tapped(0.5, 0.5), .touching(false)])
        #expect(gesture.pointer == ScreenPointer(x: 0.5, y: 0.5))
        #expect(gesture.tapped?.fx == 0.5)
    }

    @Test func aSwipeOnlyMovesThePointer() {
        var gesture = ScreenGesture()
        let control = context(control: true)
        _ = gesture.began([p(10, 10)], now: 0, control)
        #expect(gesture.moved([p(14, 12)], control) == [])                 // inside the tap slop
        #expect(gesture.moved([p(30, 10)], control) == [.pointerMoved])
        #expect(gesture.holdDeadline == nil)
        #expect(gesture.moved([p(60, 20)], control) == [.pointerMoved])
        #expect(close(gesture.pointer.x, 0.5 + 50.0 / 400.0) && close(gesture.pointer.y, 0.5 + 10.0 / 250.0))
        #expect(gesture.ended(remaining: 0, now: 0.4, control) == [.touching(false)])
        // The next touch starts from where the pointer is, wherever the finger lands.
        _ = gesture.began([p(300, 200)], now: 1, control)
        _ = gesture.moved([p(280, 180)], control)
        #expect(close(gesture.pointer.x, 0.5 + 30.0 / 400.0) && close(gesture.pointer.y, 0.5 - 10.0 / 250.0))
    }

    @Test func aSwipeCannotTurnIntoAClickOrDragAfterResting() {
        var gesture = ScreenGesture()
        let control = context(control: true)
        _ = gesture.began([p(10, 10)], now: 0, control)
        _ = gesture.moved([p(50, 30)], control)
        #expect(gesture.holdFired(now: 1) == [])
        #expect(gesture.moved([p(60, 40)], control) == [.pointerMoved])
        #expect(gesture.ended(remaining: 0, now: 1.1, control) == [.touching(false)])
        #expect(!gesture.pressed)
    }

    @Test func aStillHoldLiftedRightClicks() {
        var gesture = ScreenGesture()
        let control = context(control: true)
        _ = gesture.began([p(70, 80)], now: 0, control)
        #expect(gesture.holdFired(now: 0.3) == [])                          // not yet
        #expect(gesture.holdFired(now: 0.6) == [.holdArmed])
        #expect(gesture.holdFired(now: 0.7) == [])                          // once
        #expect(gesture.ended(remaining: 0, now: 0.8, control) == [.click(4), .tapped(0.5, 0.5), .touching(false)])
    }

    @Test func aHoldThatThenMovesIsALeftDrag() {
        var gesture = ScreenGesture()
        let control = context(control: true)
        _ = gesture.began([p(70, 80)], now: 0, control)
        _ = gesture.holdFired(now: 0.7)
        #expect(gesture.moved([p(120, 80)], control) == [.buttons(1), .pointerMoved])
        #expect(gesture.pressed)
        #expect(gesture.moved([p(130, 80)], control) == [.pointerMoved])
        let pointer = gesture.pointer
        #expect(gesture.ended(remaining: 0, now: 1, control) == [.buttons(0), .tapped(pointer.x, pointer.y), .touching(false)])
        #expect(!gesture.pressed)
    }

    @Test func aCancelledTouchNeverClicksAndACancelledDragIsReleased() {
        var gesture = ScreenGesture()
        let control = context(control: true)
        _ = gesture.began([p(40, 60)], now: 0, control)
        #expect(gesture.cancelled() == [.touching(false)])
        _ = gesture.began([p(10, 10)], now: 1, control)
        _ = gesture.holdFired(now: 1.7)
        _ = gesture.moved([p(50, 30)], control)
        #expect(gesture.cancelled() == [.buttons(0), .touching(false)])
        #expect(!gesture.pressed)
        // And the touch after it is a fresh one.
        _ = gesture.began([p(40, 60)], now: 3, control)
        #expect(gesture.ended(remaining: 0, now: 3.1, control).first == .click(1))
    }

    @Test func aSecondFingerEndsADragWhereItIs() {
        var gesture = ScreenGesture()
        let control = context(control: true)
        _ = gesture.began([p(10, 10)], now: 0, control)
        _ = gesture.holdFired(now: 0.7)
        _ = gesture.moved([p(80, 40)], control)
        #expect(gesture.began([p(80, 40), p(200, 40)], now: 1, control) == [.buttons(0)])
        #expect(!gesture.pressed)
        // Lifting both never clicks.
        #expect(gesture.ended(remaining: 1, now: 1.2, control) == [.view(.fit, committed: true)])
        #expect(gesture.ended(remaining: 0, now: 1.3, control) == [.touching(false)])
    }

    @Test func pinchZoomsLocallyInBothModes() {
        for control in [false, true] {
            var gesture = ScreenGesture()
            let ctx = context(control: control)
            #expect(gesture.began([p(150, 125), p(250, 125)], now: 0, ctx) == [])
            let actions = gesture.moved([p(100, 125), p(300, 125)], ctx)
            #expect(actions == [.view(ScreenView(zoom: 2, x: -200, y: -125), committed: false)])
            #expect(gesture.ended(remaining: 1, now: 0.5, ctx) == [.view(ScreenView(zoom: 2, x: -200, y: -125), committed: true)])
            #expect(gesture.ended(remaining: 0, now: 0.6, ctx) == [.touching(false)])
            #expect(gesture.view.zoom == 2)
        }
    }

    @Test func twoFingersAtFitScrollTheRemoteScreenInWheelSteps() {
        var gesture = ScreenGesture()
        let control = context(control: true)
        _ = gesture.began([p(150, 200), p(250, 200)], now: 0, control)
        // Fingers up 50 pt: two steps down (24 pt each), the remainder carries.
        #expect(gesture.moved([p(150, 150), p(250, 150)], control) == [.wheel(down: true), .wheel(down: true)])
        #expect(gesture.moved([p(150, 127), p(250, 127)], control) == [.wheel(down: true)])
        // And back down: up steps.
        #expect(gesture.moved([p(150, 200), p(250, 200)], control) == [.wheel(down: false), .wheel(down: false), .wheel(down: false)])
        #expect(gesture.ended(remaining: 0, now: 1, control) == [.touching(false)])
        #expect(gesture.view == .fit)
        // Watching, the same drag is no scroll (nothing may be sent) and no zoom.
        var watching = ScreenGesture()
        let watch = context(control: false)
        _ = watching.began([p(150, 200), p(250, 200)], now: 0, watch)
        let watched = watching.moved([p(150, 150), p(250, 150)], watch)
        #expect(!watched.contains(.wheel(down: true)) && !watched.contains(.wheel(down: false)))
        // Zoomed in, two fingers move the view instead of scrolling.
        var zoomed = ScreenGesture()
        zoomed.setView(ScreenView(zoom: 2, x: -100, y: -100), control)
        _ = zoomed.began([p(150, 200), p(250, 200)], now: 0, control)
        let panned = zoomed.moved([p(150, 150), p(250, 150)], control)
        #expect(!panned.contains(.wheel(down: true)) && !panned.contains(.wheel(down: false)))
    }

    @Test func watchingDoubleTapZoomsDragPansDoubleTapFits() {
        var gesture = ScreenGesture()
        let watch = context(control: false)
        #expect(gesture.began([p(100, 100)], now: 0, watch) == [])
        #expect(gesture.holdDeadline == nil)
        #expect(gesture.ended(remaining: 0, now: 0.05, watch) == [.touching(false)])
        _ = gesture.began([p(100, 100)], now: 0.2, watch)
        let actions = gesture.ended(remaining: 0, now: 0.25, watch)
        #expect(actions.first == .view(gesture.view, committed: true))
        #expect(gesture.view.zoom == 2.5)
        let x = gesture.view.x
        _ = gesture.began([p(200, 100)], now: 2, watch)
        _ = gesture.moved([p(150, 100)], watch)
        _ = gesture.moved([p(120, 100)], watch)
        _ = gesture.ended(remaining: 0, now: 2.5, watch)
        #expect(gesture.view.x == x - 80)
        _ = gesture.began([p(50, 50)], now: 4, watch)
        _ = gesture.ended(remaining: 0, now: 4.05, watch)
        _ = gesture.began([p(50, 50)], now: 4.2, watch)
        _ = gesture.ended(remaining: 0, now: 4.25, watch)
        #expect(gesture.view == .fit)
        // Two slow taps, or two far apart, are not a double tap.
        _ = gesture.began([p(50, 50)], now: 6, watch)
        _ = gesture.ended(remaining: 0, now: 6.05, watch)
        _ = gesture.began([p(50, 50)], now: 7, watch)
        _ = gesture.ended(remaining: 0, now: 7.05, watch)
        #expect(gesture.view == .fit)
        _ = gesture.began([p(300, 200)], now: 7.1, watch)
        _ = gesture.ended(remaining: 0, now: 7.15, watch)
        #expect(gesture.view == .fit)
    }

    @Test func fittingALandscapeDesktopInAPortraitStageCentresIt() {
        var gesture = ScreenGesture()
        let watch = context(control: false, stage: CGSize(width: 402, height: 600), framebuffer: (1024, 640))
        gesture.setView(.fit, watch)
        #expect(gesture.view == ScreenView(zoom: 1, x: 0, y: (600 - 251.25) / 2))
        for now in [0.0, 0.2] {
            _ = gesture.began([p(100, 100)], now: now, watch)
            _ = gesture.ended(remaining: 0, now: now + 0.05, watch)
        }
        #expect(close(gesture.view.zoom, 600 / 251.25))
        for now in [2.0, 2.2] {
            _ = gesture.began([p(50, 50)], now: now, watch)
            _ = gesture.ended(remaining: 0, now: now + 0.05, watch)
        }
        #expect(gesture.view == ScreenView(zoom: 1, x: 0, y: (600 - 251.25) / 2))
    }

    @Test func theBlackBandsAreTrackpadToo() {
        // A 1200x600 desktop drawn 400x200 in a 400x600 stage: the finger below the picture still moves the pointer.
        var gesture = ScreenGesture()
        let control = context(control: true, stage: CGSize(width: 400, height: 600), framebuffer: (1200, 600))
        _ = gesture.began([p(100, 450)], now: 0, control)
        #expect(gesture.moved([p(140, 420)], control) == [.pointerMoved])
        #expect(close(gesture.pointer.x, 0.6) && close(gesture.pointer.y, 0.35))
        _ = gesture.moved([p(5000, 5000)], control)
        #expect(gesture.pointer.pixel((1200, 600)) == (1199, 599))
        _ = gesture.moved([p(4980, 4980)], control)                         // back 20 pt: no dead zone at the edge
        #expect(close(gesture.pointer.x, 1 - 1.0 / 1200 - 0.05))
    }

    @Test func droppingControlForgetsTheTouchAndSaysAButtonWasDown() {
        var gesture = ScreenGesture()
        let control = context(control: true)
        _ = gesture.began([p(10, 10)], now: 0, control)
        _ = gesture.holdFired(now: 0.7)
        _ = gesture.moved([p(60, 60)], control)
        let wasDown = gesture.drop()
        #expect(wasDown)
        #expect(!gesture.pressed)
        let again = gesture.drop()
        #expect(!again)
        // The finger still on the glass does nothing more.
        #expect(gesture.moved([p(90, 90)], control) == [])
        #expect(gesture.ended(remaining: 0, now: 2, control) == [.touching(false)])
    }

    @Test func relayoutKeepsTheViewLegalAndTheTappedRowInSight() {
        var gesture = ScreenGesture()
        let tall = context(control: true, stage: CGSize(width: 400, height: 600), framebuffer: (400, 600))
        _ = gesture.began([p(10, 10)], now: 0, tall)
        _ = gesture.moved([p(10, 250)], tall)                                 // the pointer goes down to 0.9
        _ = gesture.ended(remaining: 0, now: 0.2, tall)
        _ = gesture.began([p(10, 10)], now: 1, tall)
        _ = gesture.ended(remaining: 0, now: 1.1, tall)                      // a click there
        #expect(close(gesture.tapped?.fy ?? 0, 0.9))
        gesture.setView(ScreenView(zoom: 2, x: 0, y: 0), tall)
        // The keyboard takes half the stage: the tapped row (y = 1080 of 1200) is brought 40 pt clear of the bottom.
        let short = context(control: true, stage: CGSize(width: 400, height: 300), framebuffer: (400, 600))
        gesture.relayout(short)
        let rect = ScreenViewMath.drawn(stage: short.stage, aspect: short.aspect, view: gesture.view)
        let row = rect.minY + 0.9 * rect.height
        #expect(row <= 300 - 40 + 0.001 && row >= 40 - 0.001)
        // A resize of the desktop keeps the pointer inside it.
        gesture.clampPointer(context(control: true, stage: CGSize(width: 400, height: 300), framebuffer: (2, 2)))
        #expect(gesture.pointer.pixel((2, 2)) == (1, 1) || gesture.pointer.pixel((2, 2)) == (0, 1))
    }
}
