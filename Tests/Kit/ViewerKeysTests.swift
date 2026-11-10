// [mac] Mac stress test round 2, #37 and #38: the viewers' zoom keys and wheel, and ← / → across photos
// (HermesKit/Layout/ViewerKeys.swift).
import CoreGraphics
import Testing
@testable import HermesHQNative

struct ViewerKeysTests {
    @Test func zoomKeys() {
        #expect(ZoomStep.forKey("=") == .zoomIn)
        #expect(ZoomStep.forKey("+") == .zoomIn)
        #expect(ZoomStep.forKey("-") == .zoomOut)
        #expect(ZoomStep.forKey("_") == .zoomOut)
        #expect(ZoomStep.forKey("0") == .fit)
        #expect(ZoomStep.forKey("1") == nil)
        #expect(ZoomStep.forKey("") == nil)
    }

    @Test func aStepInThenOutIsWhereItStarted() {
        let inward = ZoomStep.zoomIn.factor ?? 0, outward = ZoomStep.zoomOut.factor ?? 0
        #expect(inward == 1.5)
        #expect(abs(inward * outward - 1) < 1e-9)
        #expect(ZoomStep.fit.factor == nil)
    }

    @Test func scrollUpZoomsInAndDownZoomsOut() {
        for discrete in [false, true] {
            #expect(ZoomStep.scrollFactor(10, discrete: discrete) > 1)
            #expect(ZoomStep.scrollFactor(-10, discrete: discrete) < 1)
            #expect(ZoomStep.scrollFactor(0, discrete: discrete) == 1)
            #expect(ZoomStep.scrollFactor(.nan, discrete: discrete) == 1)
            // Up then down by the same travel comes back.
            #expect(abs(ZoomStep.scrollFactor(7, discrete: discrete) * ZoomStep.scrollFactor(-7, discrete: discrete) - 1) < 1e-9)
        }
        // A trackpad doubles every 200 pt; a mouse notch (10 pt) moves more than the same trackpad travel.
        #expect(abs(ZoomStep.scrollFactor(100, discrete: false) - 2.0.squareRoot()) < 1e-9)
        #expect(ZoomStep.scrollFactor(10, discrete: true) > ZoomStep.scrollFactor(10, discrete: false))
    }

    @Test func oneScrollEventNeverMovesMoreThanAStep() {
        #expect(ZoomStep.scrollFactor(10_000, discrete: false) == ZoomStep.stepFactor)
        #expect(ZoomStep.scrollFactor(-10_000, discrete: true) == 1 / ZoomStep.stepFactor)
    }

    @Test func pagingStopsAtEitherEnd() {
        #expect(PhotoPaging.step(from: 0, count: 3, forward: true) == 1)
        #expect(PhotoPaging.step(from: 1, count: 3, forward: true) == 2)
        #expect(PhotoPaging.step(from: 2, count: 3, forward: true) == nil)
        #expect(PhotoPaging.step(from: 2, count: 3, forward: false) == 1)
        #expect(PhotoPaging.step(from: 0, count: 3, forward: false) == nil)
    }

    @Test func oneOrNoPhotosNeverPage() {
        #expect(PhotoPaging.step(from: 0, count: 1, forward: true) == nil)
        #expect(PhotoPaging.step(from: 0, count: 1, forward: false) == nil)
        #expect(PhotoPaging.step(from: 0, count: 0, forward: true) == nil)
        #expect(PhotoPaging.step(from: 5, count: 3, forward: false) == nil)   // an index out of range goes nowhere
    }
}
