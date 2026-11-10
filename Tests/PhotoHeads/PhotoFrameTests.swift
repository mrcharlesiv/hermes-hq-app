// [photoheads] Move and Scale geometry (docs/spec/3x-photoheads.md §7.2, §11.1 item 1): the web app's own vectors
// (`src/photo-framer.test.ts:15-41`, a 400 × 200 photo) and the edges the web does not test.

import CoreGraphics
import Foundation
import Testing
@testable import HermesHQNative

struct PhotoFrameTests {
    private let wide = CGSize(width: 400, height: 200)

    private func close(_ a: Double, _ b: Double, _ slack: Double = 1e-9) -> Bool { abs(a - b) <= slack }

    // MARK: the web's vectors

    @Test func startsFillingTheFrameWithTheShortSideCentred() {
        #expect(PhotoFrame.start.rect(wide, edge: 100) == CGRect(x: -50, y: 0, width: 200, height: 100))
        #expect(!PhotoFrame.start.leavesGaps(wide))
    }

    @Test func zoomsOutOnlyAsFarAsTheWholePhotoFittingAndInToTheLimit() {
        #expect(PhotoFrame.minZoom(wide) == 0.5)
        #expect(PhotoFrame(zoom: 0.1, x: 0, y: 0).clamped(wide).zoom == 0.5)
        #expect(PhotoFrame(zoom: 99, x: 0, y: 0).clamped(wide).zoom == PhotoFrame.maxZoom)
        #expect(PhotoFrame.maxZoom == 5)
        #expect(PhotoFrame(zoom: 0.5, x: 0, y: 0).leavesGaps(wide))
    }

    @Test func aPhotoThatCoversTheFrameCannotBeDraggedToLeaveAGap() {
        // At zoom 1 the wide photo is 2 frames wide: half a frame of slack each way, none vertically.
        #expect(PhotoFrame.start.panned(wide, dx: 3, dy: 3) == PhotoFrame(zoom: 1, x: 0.5, y: 0))
        let rect = PhotoFrame.start.panned(wide, dx: -3, dy: 0).rect(wide, edge: 100)
        #expect(rect.minX + rect.width == 100)
    }

    @Test func aPhotoSmallerThanTheFrameStaysInsideIt() {
        let fitted = PhotoFrame(zoom: 0.5, x: 0, y: 0).panned(wide, dx: 0, dy: 1)
        #expect(close(fitted.y, 0.25))
        let rect = fitted.rect(wide, edge: 100)
        #expect(close(rect.minY + rect.height, 100, 1e-6))
    }

    @Test func aPinchKeepsThePointUnderTheFingersInPlace() {
        let square = CGSize(width: 300, height: 300)
        #expect(PhotoFrame.start.zoomed(square, ratio: 2, focusX: 0.25, focusY: 0.25) == PhotoFrame(zoom: 2, x: -0.25, y: -0.25))
    }

    // MARK: the edges

    @Test func aSquarePhotoCannotZoomOutPastFilling() {
        let square = CGSize(width: 512, height: 512)
        #expect(PhotoFrame.minZoom(square) == 1)
        #expect(PhotoFrame(zoom: 0.2, x: 0, y: 0).clamped(square) == .start)
        #expect(!PhotoFrame.start.leavesGaps(square))
        // Nothing to drag at zoom 1: the photo is exactly the frame.
        #expect(PhotoFrame.start.panned(square, dx: 0.4, dy: -0.4) == .start)
    }

    @Test func aSliverOfAPhoto() {
        let sliver = CGSize(width: 1, height: 1000)
        #expect(PhotoFrame.minZoom(sliver) == 0.001)
        let fitted = PhotoFrame(zoom: 0, x: 0, y: 0).clamped(sliver)
        #expect(fitted.zoom == 0.001)
        let rect = fitted.rect(sliver, edge: 256)
        #expect(close(rect.height, 256, 1e-6))
        #expect(close(rect.width, 0.256, 1e-6))
        #expect(fitted.leavesGaps(sliver))
        // At zoom 1 it is one frame wide and a thousand tall: it can travel 499.5 frames up or down, none sideways.
        let far = PhotoFrame.start.panned(sliver, dx: 9, dy: 9999)
        #expect(far.x == 0)
        #expect(close(far.y, 499.5))
    }

    @Test(arguments: [CGSize.zero, CGSize(width: 0, height: 40), CGSize(width: 40, height: 0),
                      CGSize(width: CGFloat.nan, height: 10), CGSize(width: CGFloat.infinity, height: 10)])
    func anEmptyPhotoNeverDividesByZero(_ empty: CGSize) {
        #expect(PhotoFrame.minZoom(empty) == 1)
        let view = PhotoFrame(zoom: .nan, x: .infinity, y: -.infinity).clamped(empty)
        #expect(view.zoom.isFinite && view.x.isFinite && view.y.isFinite)
        let moved = PhotoFrame.start.panned(empty, dx: 2, dy: 2).zoomed(empty, ratio: 3, focusX: 0.1, focusY: 0.1)
        #expect(moved.zoom.isFinite && moved.x.isFinite && moved.y.isFinite)
        if empty == .zero {
            let rect = PhotoFrame.start.rect(empty, edge: 256)
            #expect(rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite)
        }
    }

    @Test func zoomingAtTheLimitsStaysClamped() {
        let top = PhotoFrame(zoom: 5, x: 0, y: 0).zoomed(wide, ratio: 4)
        #expect(top.zoom == 5)
        let bottom = PhotoFrame(zoom: 0.5, x: 0, y: 0).zoomed(wide, ratio: 0.01)
        #expect(bottom.zoom == 0.5)
        #expect(bottom.x == 0 && bottom.y == 0)
        // A bad ratio (a recogniser reporting nothing useful) leaves a usable view.
        for ratio in [Double.nan, .infinity, 0, -3] {
            let view = PhotoFrame.start.zoomed(wide, ratio: ratio)
            #expect(view.zoom >= 0.5 && view.zoom <= 5 && view.x.isFinite && view.y.isFinite, "ratio \(ratio)")
        }
        // Zooming out from a far corner pulls the photo back so it still covers what it can.
        let corner = PhotoFrame(zoom: 4, x: 3.5, y: 1.5).clamped(wide)
        let out = corner.zoomed(wide, ratio: 0.25)
        #expect(out == out.clamped(wide))
        #expect(out.zoom == 1)
        #expect(abs(out.x) <= 0.5 && out.y == 0)
    }

    @Test func thePlacementSurvivesAResizeOfTheFrame() {
        let view = PhotoFrame(zoom: 1.7, x: 0.31, y: -0.12).clamped(wide)
        let small = view.rect(wide, edge: 200), big = view.rect(wide, edge: 420)
        let k = 420.0 / 200.0
        #expect(close(Double(small.minX) * k, Double(big.minX), 1e-6))
        #expect(close(Double(small.minY) * k, Double(big.minY), 1e-6))
        #expect(close(Double(small.width) * k, Double(big.width), 1e-6))
        #expect(close(Double(small.height) * k, Double(big.height), 1e-6))
    }

    @Test func theSliderRangeForATallPhoto() {
        let tall = CGSize(width: 100, height: 4000)
        #expect(PhotoFrame.minZoom(tall) == 0.025)
        let whole = PhotoFrame(zoom: 0.025, x: 0, y: 0).clamped(tall).rect(tall, edge: 400)
        #expect(close(Double(whole.height), 400, 1e-6))
        #expect(close(Double(whole.width), 10, 1e-6))
        #expect(close(Double(whole.midX), 200, 1e-6) && close(Double(whole.midY), 200, 1e-6))
    }
}
