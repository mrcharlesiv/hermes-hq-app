// The Bot Screen stage paces pointer moves with a display link; the link must not keep the stage (and its last
// full-size frame) alive after the screen goes away.

import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor struct ScreenStageLifetimeTests {
    private func picture() -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(UIColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    @Test func aStageThatPacedAMoveIsFreedWithItsPicture() {
        weak var gone: ScreenStageView?
        autoreleasepool {
            let stage = ScreenStageView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
            stage.show(picture(), width: 8, height: 8)
            stage.control = true
            stage.debugScheduleMove()
            #expect(stage.debugHasMoveLink)
            gone = stage
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(gone == nil)
    }

    @Test func droppingTouchesTakesTheLinkOffTheRunLoopAndAMoveBuildsANewOne() {
        let stage = ScreenStageView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        stage.show(picture(), width: 8, height: 8)
        stage.control = true
        stage.debugScheduleMove()
        #expect(stage.debugHasMoveLink)
        stage.dropTouches()
        #expect(!stage.debugHasMoveLink)
        stage.debugScheduleMove()
        #expect(stage.debugHasMoveLink)
    }
}
