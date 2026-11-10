// [photoheads] The picture Move and Scale stores (docs/spec/3x-photoheads.md §7.5, §11.1 item 3): always a 256 × 256
// opaque 8-bit PNG, upright, with a blurred copy of the photo in any gap.

import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import HermesHQNative

struct PhotoFramerRendererTests {
    private func rendered(_ photo: CGImage, _ view: PhotoFrame = .start) throws -> (png: Data, image: CGImage) {
        let png = try #require(PhotoFramerRenderer.png(photo: photo, view: view))
        return (png, try #require(PhotoTest.decode(png)))
    }

    private func corners(_ image: CGImage) -> [PhotoTest.RGBA] {
        let last = image.width - 1
        return [PhotoTest.pixel(image, 0, 0), PhotoTest.pixel(image, last, 0), PhotoTest.pixel(image, 0, last), PhotoTest.pixel(image, last, last)]
    }

    @Test func theOutputIsA256PixelPNG() throws {
        let out = try rendered(PhotoTest.quadrants(1024, 768))
        let header = try #require(PhotoTest.ihdr(out.png))
        #expect(header.width == 256 && header.height == 256)
        #expect(header.depth == 8)
        #expect(out.image.width == 256 && out.image.height == 256)
        // Never the size of a head's desktop copy or of desktop's own face copy.
        #expect(BotPicture.classify(found: true, dataURL: PhotoFramerRenderer.dataURL(png: out.png)).verdict == .photo)
        #expect(PhotoFramerRenderer.dataURL(png: out.png).hasPrefix("data:image/png;base64,iVBOR"))
    }

    @Test func theStartPlacementIsACentreCrop() throws {
        // 1024 × 512 at the start: the middle 512 × 512 fills the frame, so the left half is red over blue.
        let out = try rendered(PhotoTest.quadrants(1024, 512))
        #expect(PhotoTest.pixel(out.image, 30, 30).near(PhotoTest.red))
        #expect(PhotoTest.pixel(out.image, 226, 30).near(PhotoTest.green))
        #expect(PhotoTest.pixel(out.image, 30, 226).near(PhotoTest.blue))
        #expect(PhotoTest.pixel(out.image, 226, 226).near(PhotoTest.yellow))
    }

    @Test func draggingMovesWhatIsStored() throws {
        // Dragged fully to the right (x = +0.5): the frame shows the photo's left half, which is red over blue only.
        let photo = PhotoTest.quadrants(1024, 512)
        let view = PhotoFrame.start.panned(CGSize(width: 1024, height: 512), dx: 3, dy: 0)
        let out = try rendered(photo, view)
        #expect(PhotoTest.pixel(out.image, 30, 30).near(PhotoTest.red))
        #expect(PhotoTest.pixel(out.image, 226, 30).near(PhotoTest.red))
        #expect(PhotoTest.pixel(out.image, 30, 226).near(PhotoTest.blue))
        #expect(PhotoTest.pixel(out.image, 226, 226).near(PhotoTest.blue))
    }

    @Test func opaqueAtAllFourCornersWithoutGaps() throws {
        let out = try rendered(PhotoTest.quadrants(800, 800))
        #expect(corners(out.image).allSatisfy { $0.a == 255 })
        #expect(out.image.alphaInfo == .none || out.image.alphaInfo == .noneSkipLast || out.image.alphaInfo == .noneSkipFirst)
        #expect(PhotoTest.ihdr(out.png)?.colorType == 2)        // RGB, no alpha channel at all
    }

    @Test func opaqueAtAllFourCornersWithGapsAndTheGapsAreBlurredNotBlack() throws {
        // A 2000 × 500 photo zoomed all the way out: a band across the middle, gaps above and below.
        let photo = PhotoTest.quadrants(2000, 500)
        let size = CGSize(width: 2000, height: 500)
        let view = PhotoFrame(zoom: PhotoFrame.minZoom(size), x: 0, y: 0)
        #expect(view.leavesGaps(size))
        let out = try rendered(photo, view)
        #expect(PhotoTest.ihdr(out.png)?.colorType == 2)
        let found = corners(out.image)
        #expect(found.allSatisfy { $0.a == 255 })
        // The gaps carry the photo's colours, softened: none of the corners is black.
        #expect(found.allSatisfy { $0.r + $0.g + $0.b > 90 }, "corners \(found)")
        // The band itself is the sharp photo: 64 px tall, centred.
        #expect(PhotoTest.pixel(out.image, 30, 112).near(PhotoTest.red))
        #expect(PhotoTest.pixel(out.image, 226, 112).near(PhotoTest.green))
        #expect(PhotoTest.pixel(out.image, 30, 144).near(PhotoTest.blue))
        #expect(PhotoTest.pixel(out.image, 226, 144).near(PhotoTest.yellow))
        // And the backdrop is a real blur: no hard edge half-way up the top gap.
        let above = PhotoTest.pixel(out.image, 128, 20), below = PhotoTest.pixel(out.image, 128, 60)
        #expect(abs(above.r - below.r) < 80 && abs(above.g - below.g) < 80 && abs(above.b - below.b) < 80)
    }

    @Test func theBackdropIsOpaqueToItsEdge() throws {
        let backdrop = try #require(PhotoFramerRenderer.backdrop(photo: PhotoTest.quadrants(600, 300)))
        #expect(backdrop.width == 256 && backdrop.height == 256)
        #expect(corners(backdrop).allSatisfy { $0.a == 255 && $0.r + $0.g + $0.b > 90 })
        // Edge-clamped, so the rim is as bright as the inside (a plain blur would fade to dark there).
        let rim = PhotoTest.pixel(backdrop, 0, 64), inside = PhotoTest.pixel(backdrop, 24, 64)
        #expect(rim.near(inside, within: 40))
    }

    @Test func aSeeThroughPictureIsStoredOpaque() throws {
        let photo = PhotoTest.halfClear(400)
        let out = try rendered(photo)
        #expect(PhotoTest.ihdr(out.png)?.colorType == 2)
        // The clear half lands on the framer's black stage; the solid half keeps its colour.
        let left = PhotoTest.pixel(out.image, 40, 128)
        #expect(left.a == 255 && left.r < 12 && left.g < 12 && left.b < 12)
        #expect(PhotoTest.pixel(out.image, 216, 128).near(PhotoTest.green))
    }

    /// The read (`PhotoNormalizer.thumbnail`, what the picker uses) turns the picture; the renderer keeps it that way.
    @Test func aTurnedSourceComesOutUpright() throws {
        let file = PhotoTest.temporaryFile(PhotoTest.orientedJPEG(1200, 800, orientation: 6), name: "portrait.jpg")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let read = try #require(PhotoNormalizer.thumbnail(file, maxPixel: 1024))
        #expect(read.width == 1024 && (682...683).contains(read.height))
        let out = try rendered(read)
        #expect(PhotoTest.pixel(out.image, 30, 30).near(PhotoTest.red))
        #expect(PhotoTest.pixel(out.image, 226, 30).near(PhotoTest.green))
        #expect(PhotoTest.pixel(out.image, 30, 226).near(PhotoTest.blue))
        #expect(PhotoTest.pixel(out.image, 226, 226).near(PhotoTest.yellow))
    }

    @Test func aWideColourSourceGivesAnEightBitPNGUnder400KB() throws {
        let photo = PhotoTest.wideColor(1024)
        #expect(photo.bitsPerComponent == 16)
        let out = try rendered(photo)
        let header = try #require(PhotoTest.ihdr(out.png))
        #expect(header.depth == 8 && header.colorType == 2)
        #expect(out.png.count < 400_000)
        #expect(out.image.bitsPerComponent == 8)
    }

    @Test func noiseStaysUnderTheGatewaysLimit() throws {
        // The worst case for a PNG: every pixel different. Still far under the gateway's 2,000,000 bytes.
        let context = PhotoTest.context(256, 256)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 7
        for i in 0..<(256 * context.bytesPerRow) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[i] = i % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: seed >> 16)
        }
        let out = try rendered(context.makeImage()!)
        #expect(out.png.count < 400_000)
    }

    @Test func aTinyPictureAndASliverBothRender() throws {
        let tiny = try rendered(PhotoTest.flat(16, 16, PhotoTest.yellow))
        #expect(PhotoTest.pixel(tiny.image, 128, 128).near(PhotoTest.yellow))
        let size = CGSize(width: 100, height: 4000)
        let sliver = try rendered(PhotoTest.flat(100, 4000, PhotoTest.red), PhotoFrame(zoom: PhotoFrame.minZoom(size), x: 0, y: 0))
        #expect(sliver.image.width == 256 && sliver.image.height == 256)
        #expect(PhotoTest.pixel(sliver.image, 128, 128).near(PhotoTest.red))
        #expect(corners(sliver.image).allSatisfy { $0.a == 255 && $0.near(PhotoTest.red, within: 40) })
    }

    @Test func aBadPlacementIsClampedNotDrawnOffTheFrame() throws {
        let out = try rendered(PhotoTest.quadrants(512, 512), PhotoFrame(zoom: .nan, x: 40, y: -.infinity))
        #expect(PhotoTest.pixel(out.image, 30, 30).near(PhotoTest.red))
        #expect(PhotoTest.pixel(out.image, 226, 226).near(PhotoTest.yellow))
    }

    @Test func theSameInputGivesTheSameBytes() throws {
        let photo = PhotoTest.quadrants(900, 300)
        let view = PhotoFrame(zoom: 0.5, x: 0.1, y: 0)
        #expect(try rendered(photo, view).png == rendered(photo, view).png)
    }
}
