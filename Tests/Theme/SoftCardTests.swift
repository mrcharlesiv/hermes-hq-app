// [soft-cards] The Soft Cards material: how dense a card must be for the faintest words on it to read, and how a
// picture's tone is measured.

import CoreGraphics
import Testing
import UIKit
@testable import HermesHQNative

@Suite struct SoftCardTests {
    /// The contrast the rule itself promises, worked out the same way.
    private func contrast(density: Double, picture: Double, dim: Double, page: Double, ink: Double, inkAlpha: Double) -> Double {
        let under = dim * SoftCard.encoded(page) + (1 - dim) * SoftCard.encoded(picture)
        let surface = density * SoftCard.encoded(page) + (1 - density) * under
        let words = inkAlpha * SoftCard.encoded(ink) + (1 - inkAlpha) * surface
        let a = SoftCard.decoded(words) + 0.05, b = SoftCard.decoded(surface) + 0.05
        return max(a, b) / min(a, b)
    }

    @Test func aCalmPictureGetsTheLightestCard() {
        // Dark: a dark picture under the standard Dim, near-white words at 60 %.
        let density = SoftCard.density(picture: 0.02, dim: 0.45, page: 0.004, card: 0.004, ink: 0.9, inkAlpha: 0.6)
        #expect(density == SoftCard.densityRange.lowerBound)
    }

    @Test func aBrightPhotoInTheDarkGetsADenserCardThatStillReads() {
        let light = SoftCard.density(picture: 0.05, dim: 0.45, page: 0.004, card: 0.004, ink: 0.9, inkAlpha: 0.6)
        let bright = SoftCard.density(picture: 0.9, dim: 0.45, page: 0.004, card: 0.004, ink: 0.9, inkAlpha: 0.6)
        #expect(bright > light)
        #expect(contrast(density: bright, picture: 0.9, dim: 0.45, page: 0.004, ink: 0.9, inkAlpha: 0.6) >= SoftCard.contrast)
    }

    @Test func lessDimMeansADenserCard() {
        let dimmed = SoftCard.density(picture: 0.6, dim: 0.8, page: 0.004, card: 0.004, ink: 0.9, inkAlpha: 0.6)
        let bare = SoftCard.density(picture: 0.6, dim: 0, page: 0.004, card: 0.004, ink: 0.9, inkAlpha: 0.6)
        #expect(bare > dimmed)
    }

    @Test func everyPictureAndDimReadsOrIsAsDenseAsACardGets() {
        // Light (dark words on a near-white page) and dark, every picture tone and Dim.
        for (page, ink, inkAlpha) in [(0.98, 0.03, 0.6), (0.004, 0.9, 0.6), (0.03, 0.75, 1.0)] {
            for picture in stride(from: 0.0, through: 1.0, by: 0.1) {
                for dim in stride(from: 0.0, through: 0.8, by: 0.2) {
                    let density = SoftCard.density(picture: picture, dim: dim, page: page, card: page, ink: ink, inkAlpha: inkAlpha)
                    #expect(SoftCard.densityRange.contains(density))
                    let reads = contrast(density: density, picture: picture, dim: dim, page: page, ink: ink, inkAlpha: inkAlpha) >= SoftCard.contrast
                    #expect(reads || density >= SoftCard.densityRange.upperBound - 0.001, "picture \(picture), Dim \(dim), page \(page)")
                }
            }
        }
    }

    @Test func aPicturesToneIsItsBrightestAndDarkestTenths() throws {
        // Left nine tenths black, the right tenth white.
        let width = 200, height = 100
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 170, y: 0, width: 30, height: height))
        let tone = SoftCardTone.measure(try #require(context.makeImage()))
        #expect(tone.bright > 0.9 && tone.dark < 0.01)
        // One flat grey: both the same.
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let flat = SoftCardTone.measure(try #require(context.makeImage()))
        #expect(abs(flat.bright - flat.dark) < 0.01)
    }
}
