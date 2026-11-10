// [share] docs/spec/3x-share.md §7.6 checks 1–2: what a shared photo or video becomes before it leaves the phone.

import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HermesHQNative

@Suite(.serialized) struct ShareMediaTests {
    @Test func aPhoneHEICBecomesAnUprightJPEGWithoutLocationOrCamera() throws {
        // 4032×3024 stored on its side (orientation 6), with GPS, TIFF and Exif.
        let source = ShareTemp.fixtures.appendingPathComponent("photo-gps.heic")
        let before = ShareTestMedia.properties(of: try Data(contentsOf: source))
        #expect(before[kCGImagePropertyGPSDictionary] != nil && before[kCGImagePropertyTIFFDictionary] != nil)
        #expect((before[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 6)

        let jpeg = try ShareMedia.jpeg(at: source)
        #expect(ShareTestMedia.type(of: jpeg) == UTType.jpeg.identifier)
        #expect(jpeg.prefix(3) == Data([0xff, 0xd8, 0xff]))
        let after = ShareTestMedia.properties(of: jpeg)
        // Upright: the long side is now the height, and it is 3072.
        #expect((after[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 2304)
        #expect((after[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 3072)
        #expect(ShareTestMedia.carriesNothing(jpeg))
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        #expect(jpeg.count < 4 * 1024 * 1024)
    }

    /// Where the stored pixel (x, y) of a `width` x `height` file is shown once its orientation tag is applied.
    private static func shown(_ x: Int, _ y: Int, orientation: Int, width: Int, height: Int) -> (x: Int, y: Int) {
        switch orientation {
        case 2: (width - 1 - x, y)
        case 3: (width - 1 - x, height - 1 - y)
        case 4: (x, height - 1 - y)
        case 5: (y, x)
        case 6: (height - 1 - y, x)
        case 7: (height - 1 - y, width - 1 - x)
        case 8: (y, width - 1 - x)
        default: (x, y)
        }
    }

    @Test func everyOrientationEndsUpright() throws {
        let folder = ShareTemp.folder("media-orient")
        // The marked picture: red on the left, blue on the right, a green bar on top. Stored turned or mirrored,
        // tagged to match: all eight tags, the mirrored ones (2, 4, 5, 7) included.
        for orientation in 1...8 {
            let url = ShareTestMedia.photo("o\(orientation).jpg", in: folder, width: 200, height: 120, orientation: orientation)
            let jpeg = try ShareMedia.jpeg(at: url)
            #expect(ShareTestMedia.carriesNothing(jpeg), "orientation \(orientation)")
            let picture = try #require(ShareTestMedia.pixels(of: jpeg))
            let turned = orientation >= 5
            #expect(picture.width == (turned ? 120 : 200) && picture.height == (turned ? 200 : 120), "orientation \(orientation)")
            // Three stored pixels: in the green bar, in the red half and in the blue half.
            let green = Self.shown(10, 4, orientation: orientation, width: 200, height: 120)
            let red = Self.shown(20, 70, orientation: orientation, width: 200, height: 120)
            let blue = Self.shown(180, 70, orientation: orientation, width: 200, height: 120)
            let g = ShareTestMedia.colour(picture, x: green.x, y: green.y)
            let r = ShareTestMedia.colour(picture, x: red.x, y: red.y)
            let b = ShareTestMedia.colour(picture, x: blue.x, y: blue.y)
            #expect(g.g > 180 && g.r < 90 && g.b < 90, "orientation \(orientation): green is \(g)")
            #expect(r.r > 180 && r.g < 90 && r.b < 90, "orientation \(orientation): red is \(r)")
            #expect(b.b > 180 && b.r < 90 && b.g < 90, "orientation \(orientation): blue is \(b)")
        }
    }

    @Test func aJPEGDrawnInManyStripsMatchesTheSystemsOwnConversion() throws {
        // The strip path against ImageIO's thumbnail maker, for every orientation: same size, same picture, no seams.
        let folder = ShareTemp.folder("media-strips")
        let image = ShareTestMedia.bitmap(width: 1600, height: 960) { context in
            let colours = [CGColor(red: 0.95, green: 0.2, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.8, blue: 0.3, alpha: 1),
                           CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colours, locations: [0, 0.5, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1600, y: 960), options: [])
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 96, y: 96, width: 320, height: 192))                 // one corner is marked
        }
        for orientation in 1...8 {
            var properties = ShareTestMedia.camera
            properties[kCGImagePropertyOrientation] = orientation
            let url = folder.appendingPathComponent("s\(orientation).jpg")
            try ShareTestMedia.encode(image, as: .jpeg, properties: properties).write(to: url)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            // 64 KB a strip: 20 source rows at a time, so the 300 output rows come from about 24 strips.
            let ours = try #require(ShareMedia.strips(source, maxPixel: 500, quality: 0.9, stripBytes: 64 * 1024), "orientation \(orientation)")
            #expect(ShareTestMedia.carriesNothing(ours), "orientation \(orientation)")
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 500]
            let reference = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
            let theirs = try #require(ShareTestMedia.pixels(of: ShareTestMedia.encode(reference, as: .png)))
            let mine = try #require(ShareTestMedia.pixels(of: ours))
            let turned = orientation >= 5
            #expect(mine.width == (turned ? 300 : 500) && mine.height == (turned ? 500 : 300), "orientation \(orientation)")
            guard mine.width == theirs.width, mine.height == theirs.height else {
                Issue.record("orientation \(orientation): \(mine.width)x\(mine.height) against the system's \(theirs.width)x\(theirs.height)")
                continue
            }
            var total = 0, far = 0
            for index in stride(from: 0, to: mine.rgba.count, by: 4) {
                for channel in 0..<3 {
                    let difference = abs(Int(mine.rgba[index + channel]) - Int(theirs.rgba[index + channel]))
                    total += difference
                    if difference > 48 { far += 1 }
                }
            }
            let mean = Double(total) / Double(mine.width * mine.height * 3)
            #expect(mean < 3, "orientation \(orientation): mean difference \(mean)")
            // A misplaced strip would put thousands of pixels far off; an edge shifted by a pixel only a few.
            #expect(far < mine.width * mine.height * 3 / 200, "orientation \(orientation): \(far) values far off")
        }
        // The whole conversion takes this path for a camera JPEG and gives the same bytes.
        let url = folder.appendingPathComponent("s6.jpg")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(try ShareMedia.jpeg(at: url, maxPixel: 500, stripBytes: 64 * 1024)
                == ShareMedia.strips(source, maxPixel: 500, quality: ShareMedia.quality, stripBytes: 64 * 1024))
    }

    @Test func whatHasNoRowsToReadTakesTheSystemsPath() throws {
        let folder = ShareTemp.folder("media-progressive")
        // A progressive JPEG decodes whole for every strip, so it is left to ImageIO's thumbnail maker, and still
        // ends upright, without its details.
        var properties = ShareTestMedia.camera
        properties[kCGImagePropertyOrientation] = 6
        properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true]
        let progressive = folder.appendingPathComponent("progressive.jpg")
        try ShareTestMedia.encode(ShareTestMedia.marked(width: 400, height: 240), as: .jpeg, properties: properties).write(to: progressive)
        let source = try #require(CGImageSourceCreateWithURL(progressive as CFURL, nil))
        let jfif = ShareTestMedia.properties(of: try Data(contentsOf: progressive))[kCGImagePropertyJFIFDictionary] as? [CFString: Any]
        #expect((jfif?[kCGImagePropertyJFIFIsProgressive] as? NSNumber)?.boolValue == true)       // the test's file really is one
        #expect(ShareMedia.strips(source, maxPixel: 3072, quality: 0.85, stripBytes: ShareMedia.stripBytes) == nil)
        let jpeg = try ShareMedia.jpeg(at: progressive)
        let picture = try #require(ShareTestMedia.pixels(of: jpeg))
        #expect(picture.width == 240 && picture.height == 400)
        #expect(ShareTestMedia.carriesNothing(jpeg))
        let green = ShareTestMedia.colour(picture, x: picture.width - 4, y: 10)
        #expect(green.g > 180 && green.r < 90 && green.b < 90)
        // A PNG and a HEIC are not JPEGs: the same.
        let png = folder.appendingPathComponent("flat.png")
        try ShareTestMedia.encode(ShareTestMedia.marked(width: 64, height: 64), as: .png).write(to: png)
        for other in [png, ShareTemp.fixtures.appendingPathComponent("photo-gps.heic")] {
            let other = try #require(CGImageSourceCreateWithURL(other as CFURL, nil))
            #expect(ShareMedia.strips(other, maxPixel: 3072, quality: 0.85, stripBytes: ShareMedia.stripBytes) == nil)
        }
    }

    @Test func aSmallPhotoIsNotEnlargedAndLosesItsDetails() throws {
        let folder = ShareTemp.folder("media-small")
        let url = ShareTestMedia.photo("small.jpg", in: folder, width: 640, height: 480)
        #expect(!ShareTestMedia.carriesNothing(try Data(contentsOf: url)))            // the test's own photo does carry them
        let jpeg = try ShareMedia.jpeg(at: url)
        let picture = try #require(ShareTestMedia.pixels(of: jpeg))
        #expect(picture.width == 640 && picture.height == 480)
        #expect(ShareTestMedia.carriesNothing(jpeg))
        // A smaller ceiling is honoured.
        let capped = try #require(ShareTestMedia.pixels(of: try ShareMedia.jpeg(at: url, maxPixel: 320)))
        #expect(capped.width == 320 && capped.height == 240)
    }

    @Test func aFortyEightMegapixelPhotoStaysWithinTheExtensionsMemory() throws {
        // 8064×6048: decoded in full it would be 195 MB; the extension has about 120 MB in all.
        let folder = ShareTemp.folder("media-huge")
        let url = folder.appendingPathComponent("huge.jpg")
        try autoreleasepool {
            let image = ShareTestMedia.bitmap(width: 8064, height: 6048) { context in
                let colours = [CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)] as CFArray
                let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colours, locations: [0, 1])!
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 8064, y: 6048), options: [])
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                for step in 0..<40 { context.fill(CGRect(x: step * 200, y: step * 150, width: 90, height: 90)) }
            }
            try ShareTestMedia.encode(image, as: .jpeg, properties: ShareTestMedia.camera).write(to: url)
        }
        let measured = try ShareTestMedia.peakGrowth { try autoreleasepool { try ShareMedia.jpeg(at: url) } }
        let picture = ShareTestMedia.properties(of: measured.value)
        #expect((picture[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 3072)
        #expect((picture[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 2304)
        #expect(ShareTestMedia.carriesNothing(measured.value))
        #expect(measured.bytes < 60 * 1024 * 1024, "grew by \(measured.bytes / (1024 * 1024)) MB")
    }

    @Test func transparencyGoesOntoWhite() throws {
        let folder = ShareTemp.folder("media-alpha")
        let image = ShareTestMedia.bitmap(width: 80, height: 80, alpha: true) { context in
            context.clear(CGRect(x: 0, y: 0, width: 80, height: 80))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        }
        let url = folder.appendingPathComponent("clear.png")
        try ShareTestMedia.encode(image, as: .png).write(to: url)
        let picture = try #require(ShareTestMedia.pixels(of: try ShareMedia.jpeg(at: url)))
        let opaque = ShareTestMedia.colour(picture, x: 10, y: 40), clear = ShareTestMedia.colour(picture, x: 70, y: 40)
        #expect(opaque.r > 200 && opaque.g < 60 && opaque.b < 60)
        #expect(clear.r > 245 && clear.g > 245 && clear.b > 245, "transparent pixels came out \(clear), not white")
        // The app's own badge (it has an alpha channel) converts too.
        let badge = try ShareMedia.jpeg(at: ShareTemp.fixtures.appendingPathComponent("badge.png"))
        #expect(ShareTestMedia.type(of: badge) == UTType.jpeg.identifier)
        #expect((ShareTestMedia.properties(of: badge)[kCGImagePropertyHasAlpha] as? Bool) != true)
    }

    @Test func anAnimatedGIFBecomesOneStill() throws {
        let source = ShareTemp.fixtures.appendingPathComponent("spin.gif")
        #expect(ShareTestMedia.frames(of: try Data(contentsOf: source)) == 3)
        let jpeg = try ShareMedia.jpeg(at: source)
        #expect(ShareTestMedia.frames(of: jpeg) == 1)
        #expect(ShareTestMedia.type(of: jpeg) == UTType.jpeg.identifier)
        let picture = try #require(ShareTestMedia.pixels(of: jpeg))
        #expect(picture.width == 120 && picture.height == 120)
    }

    @Test func whatIsNotAPictureIsUnreadable() throws {
        let folder = ShareTemp.folder("media-bad")
        #expect(throws: ShareMedia.Failure.unreadablePhoto) { try ShareMedia.jpeg(at: ShareTemp.file("text.jpg", text: "not a picture", in: folder)) }
        #expect(throws: ShareMedia.Failure.unreadablePhoto) { try ShareMedia.jpeg(at: ShareTemp.file("empty.heic", bytes: 0, in: folder)) }
        #expect(throws: ShareMedia.Failure.unreadablePhoto) { try ShareMedia.jpeg(at: folder.appendingPathComponent("gone.png")) }
        // A picture cut off halfway (a failed AirDrop): unreadable or a JPEG, never a crash.
        let whole = try Data(contentsOf: ShareTemp.fixtures.appendingPathComponent("photo-gps.jpg"))
        let cut = folder.appendingPathComponent("cut.jpg")
        try whole.prefix(whole.count / 3).write(to: cut)
        if let jpeg = try? ShareMedia.jpeg(at: cut) { #expect(ShareTestMedia.carriesNothing(jpeg)) }
        #expect(ShareMedia.thumbnail(at: folder.appendingPathComponent("gone.png")) == nil)
    }

    @Test func thumbnailsAreSmall() throws {
        let thumbnail = try #require(ShareMedia.thumbnail(at: ShareTemp.fixtures.appendingPathComponent("photo-gps.jpg")))
        #expect(max(thumbnail.width, thumbnail.height) == ShareMedia.thumbnailPixel)
        #expect(thumbnail.height > thumbnail.width)                 // upright, as the photo is
    }

    @Test func aVideoLosesWhereItWasFilmedAndStillPlays() async throws {
        let folder = ShareTemp.folder("media-movie")
        let url = folder.appendingPathComponent("clip-gps.mov")
        try ShareTestMedia.movie(at: url)
        let before = try await ShareTestMedia.facts(ofMovieAt: url)
        #expect(try await ShareTestMedia.locations(inMovieAt: url).isEmpty == false)       // the test's own video does say where
        #expect(before.playable && before.videoTracks == 1)

        try await ShareMedia.removeLocation(fromMovieAt: url)

        #expect(try await ShareTestMedia.locations(inMovieAt: url) == [])
        let after = try await ShareTestMedia.facts(ofMovieAt: url)
        #expect(after.playable && after.videoTracks == 1)
        #expect(abs(after.seconds - before.seconds) <= 0.1, "\(before.seconds) → \(after.seconds)")
        // In place: the same file, nothing left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["clip-gps.mov"])
    }

    @Test func aVideoThatCannotBeRewrittenIsNotSent() async throws {
        let folder = ShareTemp.folder("media-broken")
        let url = ShareTemp.file("broken.mov", text: String(repeating: "these are text bytes, not a movie\n", count: 40), in: folder)
        await #expect(throws: ShareMedia.Failure.locationNotRemoved) { try await ShareMedia.removeLocation(fromMovieAt: url) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["broken.mov"])     // no half-written copy
    }
}
