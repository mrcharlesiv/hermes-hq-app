// [photoheads] The photo rule (docs/spec/3x-photoheads.md §4.1, §11.1 item 2): what counts as a photo someone chose,
// and what is only the app's own 288 px head copy, desktop's 160 px face copy, nothing, or unreadable.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HermesHQNative

struct BotPictureTests {
    // MARK: each row of the table

    @Test func nothingStored() {
        #expect(BotPicture.classify(found: false, dataURL: nil).verdict == .none)
        #expect(BotPicture.classify(found: false, dataURL: PhotoTest.dataURL(PhotoTest.png(256, 256))).verdict == .none)
        #expect(BotPicture.classify(found: true, dataURL: nil).verdict == .none)
        #expect(BotPicture.classify(found: true, dataURL: "").verdict == .none)
        #expect(BotPicture.classify(found: false, dataURL: nil).fingerprint == "")
        #expect(BotPicture.classify(found: false, dataURL: nil).png == nil)
    }

    @Test func theAppsOwnHeadCopyIsNotAPhoto() {
        let mirror = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.png(288, 288)))
        #expect(mirror.verdict == .mirror)
        #expect(mirror.png == nil)
        #expect(mirror.fingerprint.count == 16)
        // The same check the head code already uses agrees.
        #expect(HeadRecord.isHeadMirror(PhotoTest.dataURL(PhotoTest.png(288, 288))))
        #expect(BotPicture.mirrorSide == HeadRecord.mirrorSize)
    }

    @Test func aRealMirrorFromEditHeadIsAMirror() throws {
        let png = try #require(EditHeadModel.mirrorPNG(Head.defaultHead(profile: "ivy")))
        #expect(BotPicture.classify(found: true, dataURL: png).verdict == .mirror)
    }

    // MARK: a black face with no backdrop turns white on desktop's dark page

    @Test func aBlackHeadsCopyCarriesTheDarkFlipMark() throws {
        var head = Head()
        head.color = .ink
        head.tile = .none
        let url = try #require(EditHeadModel.mirrorPNG(head))
        let base64 = String(url.dropFirst("data:image/png;base64,".count))
        // Straight after the header, so the theme's substring match always finds the same characters.
        #expect(base64.dropFirst(44).hasPrefix(HeadRecord.darkFlipMark))
        // Still the app's own head copy, still a whole PNG that decodes to the 288 px picture.
        #expect(HeadRecord.isHeadMirror(url))
        #expect(BotPicture.classify(found: true, dataURL: url).verdict == .mirror)
        let bytes = try #require(Data(base64Encoded: base64))
        #expect(BotPicture.isWhole(bytes))
        let image = try #require(PhotoTest.decode(bytes))
        #expect(image.width == 288 && image.height == 288)
        // The chunk is a valid tEXt chunk: its CRC covers type and data.
        let chunk = try #require(Data(base64Encoded: HeadRecord.darkFlipMark))
        #expect(chunk.dropFirst(4).prefix(4) == Data("tEXt".utf8))
        #expect(chunk.dropFirst(8).dropLast(4) == Data("hermes-hq\u{0}invert-on-dark".utf8))
        #expect(chunk.suffix(4).reduce(0) { ($0 << 8) | UInt32($1) } == crc32(chunk.dropFirst(4).dropLast(4)))
    }

    @Test func onlyAHeadAnInversionDrawsRightIsMarked() throws {
        func marked(_ change: (inout Head) -> Void) throws -> Bool {
            var head = Head()
            head.color = .ink
            head.tile = .none
            change(&head)
            return try #require(EditHeadModel.mirrorPNG(head)).contains(HeadRecord.darkFlipMark)
        }
        #expect(try marked { _ in })
        #expect(try marked { $0.specs = .round })
        #expect(try !marked { $0.color = .mint })
        #expect(try !marked { $0.color = .paper })
        #expect(try !marked { $0.tile = .dark })
        #expect(try !marked { $0.tile = .light })
        // The copy is drawn plain (`Head.plain`): saved cheeks, other eyes and glasses aren't in it, so they don't
        // stop the mark.
        #expect(try marked { $0.blush = true })
        #expect(try marked { $0.look = .hearts })
        #expect(try marked { $0.look = .googly })
        #expect(try marked { $0.specs = .shades })
        #expect(try marked { $0.specs = .aviators })
        #expect(try marked { $0.specs = .monocle })
        #expect(try !marked { $0.themed = HeadRecord(theme: "robot", color: "ink") })
    }

    @Test func theDesktopThemeMatchesTheSameMark() throws {
        let theme = try #require(DesktopThemeInstall.bundledText())
        #expect(theme.contains("html.dark img[src*='\(HeadRecord.darkFlipMark)']{filter:invert(1)!important}"))
    }

    @Test func markingLeavesAnythingButAPNGAlone() {
        let jpeg = PhotoTest.jpeg(288, 288)
        #expect(HeadRecord.withDarkFlipMark(jpeg) == jpeg)
        #expect(HeadRecord.withDarkFlipMark(Data()) == Data())
    }

    private func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    @Test func desktopsFaceCopyIsNotAPhoto() {
        let backfill = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.png(160, 160)))
        #expect(backfill.verdict == .backfill)
        #expect(backfill.png == nil)
    }

    @Test func aChosenPictureIsAPhoto() throws {
        let bytes = PhotoTest.png(256, 256, PhotoTest.red)
        let photo = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(bytes))
        #expect(photo.verdict == .photo)
        #expect(photo.width == 256 && photo.height == 256)
        #expect(photo.fingerprint == BotPicture.fingerprint(bytes))
        let kept = try #require(photo.png.flatMap(PhotoTest.decode))
        #expect(PhotoTest.pixel(kept, 128, 128).near(PhotoTest.red))
    }

    // MARK: the near misses

    @Test func aJPEGTheSizeOfAMirrorIsAPhoto() {
        #expect(BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.jpeg(288, 288), mime: "image/jpeg")).verdict == .photo)
        #expect(BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.jpeg(160, 160), mime: "image/jpeg")).verdict == .photo)
    }

    @Test func aPNGOnePixelOffIsAPhoto() {
        #expect(BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.png(288, 289))).verdict == .photo)
        #expect(BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.png(289, 288))).verdict == .photo)
        #expect(BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.png(160, 161))).verdict == .photo)
        #expect(BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.png(159, 160))).verdict == .photo)
    }

    /// DECISION D2: the rule reads the bytes only, so there is nothing for `imageKind: "photo"` to override.
    @Test func aBackfillStaysABackfillWhateverTheMetaSays() {
        let url = PhotoTest.dataURL(PhotoTest.png(160, 160, PhotoTest.yellow))
        #expect(BotPicture.classify(found: true, dataURL: url).verdict == .backfill)
    }

    @Test func aPetSizedPictureIsAPhoto() {
        let pet = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.png(96, 104)))
        #expect(pet.verdict == .photo)
        #expect(pet.width == 96 && pet.height == 104)
    }

    @Test func theLabelOnTheBytesDoesNotDecide() {
        // A mirror labelled JPEG is still a mirror; a JPEG labelled PNG is still a photo; bare base64 is read too.
        let mirror = PhotoTest.png(288, 288)
        #expect(BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(mirror, mime: "image/jpeg")).verdict == .mirror)
        #expect(BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.jpeg(288, 288), mime: "image/png")).verdict == .photo)
        #expect(BotPicture.classify(found: true, dataURL: mirror.base64EncodedString()).verdict == .mirror)
        #expect(BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.png(300, 200), mime: "application/octet-stream")).verdict == .photo)
    }

    @Test func webPIsAPhoto() throws {
        let bytes = try #require(Data(base64Encoded: PhotoTest.webpBase64))
        let webp = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(bytes, mime: "image/webp"))
        #expect(webp.verdict == .photo)
        #expect(webp.width == 96 && webp.height == 96)
        // The mark the stand-in gateway's picture carries: teal field, yellow centre.
        let kept = try #require(webp.png.flatMap(PhotoTest.decode))
        #expect(PhotoTest.pixel(kept, 4, 4).near(PhotoTest.RGBA(r: 0x1F, g: 0xA7, b: 0xA0, a: 255), within: 12))
        #expect(PhotoTest.pixel(kept, 48, 48).near(PhotoTest.RGBA(r: 0xFF, g: 0xD2, b: 0x3F, a: 255), within: 12))
    }

    // MARK: unreadable

    @Test func badBase64() {
        #expect(BotPicture.classify(found: true, dataURL: "data:image/png;base64,@@@not base64@@@").verdict == .unreadable)
        #expect(BotPicture.classify(found: true, dataURL: "data:image/png;base64,").verdict == .unreadable)
        #expect(BotPicture.classify(found: true, dataURL: "data:image/png,plain").verdict == .unreadable)
        #expect(BotPicture.classify(found: true, dataURL: "data:image/png").verdict == .unreadable)
    }

    @Test func aPNGHeaderWithNoBody() {
        let whole = PhotoTest.png(200, 200, PhotoTest.green)
        // The signature, the IHDR and the start of the pixel data: what a cut-off upload leaves.
        for keep in [33, 60, whole.count / 2] {
            let cut = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(whole.prefix(keep)))
            #expect(cut.verdict == .unreadable, "kept \(keep) of \(whole.count) bytes")
            #expect(cut.png == nil)
        }
    }

    @Test func aCutJPEGIsUnreadable() {
        let whole = PhotoTest.encode(PhotoTest.quadrants(640, 480), type: .jpeg)
        let cut = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(whole.prefix(whole.count / 2), mime: "image/jpeg"))
        #expect(cut.verdict == .unreadable)
    }

    /// ImageIO draws half a file and calls it complete, so `isWhole` reads each format's own end mark.
    @Test func aFileThatStopsEarlyIsNotWhole() throws {
        let noisy = PhotoTest.quadrants(640, 480)
        let files: [(String, Data)] = [
            ("png", PhotoTest.encode(noisy, type: .png)),
            ("jpeg", PhotoTest.encode(noisy, type: .jpeg)),
            ("jpeg with exif", PhotoTest.orientedJPEG(600, 400, orientation: 6)),
            ("progressive jpeg", PhotoTest.encode(noisy, type: .jpeg, properties: [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]])),
            ("gif", PhotoTest.encode(noisy, type: .gif)),
            ("webp", try #require(Data(base64Encoded: PhotoTest.webpBase64))),
        ]
        for (name, whole) in files {
            #expect(BotPicture.isWhole(whole), "\(name)")
            #expect(BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(whole)).verdict == .photo, "\(name)")
            for keep in [12, 40, whole.count / 4, whole.count / 2, whole.count - 200, whole.count - 1] where keep > 0 && keep < whole.count {
                let cut = Data(whole.prefix(keep))
                #expect(!BotPicture.isWhole(cut), "\(name) cut to \(keep) of \(whole.count)")
                #expect(BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(cut)).verdict == .unreadable, "\(name) cut to \(keep)")
            }
            // Bytes after the end mark (some cameras add them) do not make a whole file a cut one.
            #expect(BotPicture.isWhole(whole + Data(repeating: 0, count: 64)), "\(name) with a tail")
            // A slice of a bigger buffer is read from its own start.
            let padded = Data(repeating: 0xAB, count: 7) + whole
            #expect(BotPicture.isWhole(padded[7...]), "\(name) as a slice")
        }
        // Not one of the formats with an end mark: ImageIO decides (and says no to text).
        #expect(BotPicture.isWhole(Data("plain text".utf8)))
        #expect(!BotPicture.isWhole(Data()))
        #expect(!BotPicture.isWhole(Data([0xFF, 0xD8, 0xFF])))
        #expect(!BotPicture.isWhole(Data([0x89, 0x50, 0x4E, 0x47])))
    }

    @Test func aCutHEICIsNotWhole() throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { return }       // no HEIC writer here
        CGImageDestinationAddImage(destination, PhotoTest.quadrants(640, 480), nil)
        guard CGImageDestinationFinalize(destination) else { return }
        let whole = data as Data
        #expect(BotPicture.isWhole(whole))
        #expect(!BotPicture.isWhole(Data(whole.prefix(whole.count / 2))))
        #expect(!BotPicture.isWhole(Data(whole.dropLast(1))))
    }

    @Test func textIsUnreadable() {
        let text = Data("this is not a picture, it only has a picture's name\n".utf8)
        #expect(BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(text)).verdict == .unreadable)
    }

    // MARK: the kept copy

    @Test func aBigPictureIsKeptSmall() throws {
        let big = PhotoTest.encode(PhotoTest.quadrants(4000, 3000), type: .jpeg)
        let photo = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(big, mime: "image/jpeg"))
        #expect(photo.verdict == .photo)
        #expect(photo.width == 256 && photo.height == 192)
        let png = try #require(photo.png)
        #expect(png.count < 400_000)
        let header = try #require(PhotoTest.ihdr(png))
        #expect(header.width == 256 && header.height == 192 && header.depth == 8)
    }

    @Test func aTurnedPictureIsKeptUpright() throws {
        let turned = PhotoTest.orientedJPEG(600, 400, orientation: 6)
        let photo = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(turned, mime: "image/jpeg"))
        #expect(photo.verdict == .photo)
        #expect(photo.width == 256 && (170...171).contains(photo.height))
        let kept = try #require(photo.png.flatMap(PhotoTest.decode))
        #expect(PhotoTest.pixel(kept, 20, 20).near(PhotoTest.red))
        #expect(PhotoTest.pixel(kept, 236, 20).near(PhotoTest.green))
        #expect(PhotoTest.pixel(kept, 20, 150).near(PhotoTest.blue))
        #expect(PhotoTest.pixel(kept, 236, 150).near(PhotoTest.yellow))
    }

    /// Stress plan §12.4 item 3: every EXIF orientation of one picture is kept upright.
    @Test(arguments: 1...8)
    func everyOrientationIsKeptUpright(_ orientation: Int) throws {
        let turned = PhotoTest.orientedJPEG(600, 400, orientation: orientation)
        let photo = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(turned, mime: "image/jpeg"))
        #expect(photo.verdict == .photo)
        #expect(photo.width == 256 && (170...171).contains(photo.height), "orientation \(orientation): \(photo.width) × \(photo.height)")
        let kept = try #require(photo.png.flatMap(PhotoTest.decode))
        #expect(PhotoTest.pixel(kept, 20, 20).near(PhotoTest.red), "orientation \(orientation) top-left")
        #expect(PhotoTest.pixel(kept, 236, 20).near(PhotoTest.green), "orientation \(orientation) top-right")
        #expect(PhotoTest.pixel(kept, 20, 150).near(PhotoTest.blue), "orientation \(orientation) bottom-left")
        #expect(PhotoTest.pixel(kept, 236, 150).near(PhotoTest.yellow), "orientation \(orientation) bottom-right")
    }

    @Test func aWideColourPictureIsKeptAsEightBit() throws {
        let wide = PhotoTest.encode(PhotoTest.wideColor(512), type: .png)
        #expect(PhotoTest.ihdr(wide)?.depth == 16)
        let photo = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(wide))
        #expect(photo.verdict == .photo)
        #expect(PhotoTest.ihdr(try #require(photo.png))?.depth == 8)
    }

    @Test func aSmallPictureIsNotEnlarged() {
        let tiny = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.png(16, 16)))
        #expect(tiny.verdict == .photo)
        #expect(tiny.width == 16 && tiny.height == 16)
        let dot = BotPicture.classify(found: true, dataURL: PhotoTest.dataURL(PhotoTest.png(1, 1)))
        #expect(dot.verdict == .photo)
        #expect(dot.width == 1 && dot.height == 1)
    }

    // MARK: the small parts

    @Test func fingerprintsAreSixteenHexAndFollowTheBytes() {
        let a = PhotoTest.png(256, 256, PhotoTest.red), b = PhotoTest.png(256, 256, PhotoTest.blue)
        #expect(BotPicture.fingerprint(a).count == 16)
        #expect(BotPicture.fingerprint(a).allSatisfy { $0.isHexDigit })
        #expect(BotPicture.fingerprint(a) == BotPicture.fingerprint(a))
        #expect(BotPicture.fingerprint(a) != BotPicture.fingerprint(b))
        #expect(BotPicture.fingerprint(Data("abc".utf8)) == "ba7816bf8f01cfea")
    }

    @Test func pngSizeReadsTheHeaderOnly() {
        #expect(BotPicture.pngSize(PhotoTest.png(288, 160))?.width == 288)
        #expect(BotPicture.pngSize(PhotoTest.png(288, 160))?.height == 160)
        #expect(BotPicture.pngSize(PhotoTest.jpeg(288, 288)) == nil)
        #expect(BotPicture.pngSize(Data()) == nil)
        #expect(BotPicture.pngSize(PhotoTest.png(288, 288).prefix(20)) == nil)
        // A slice of a larger buffer (its indices do not start at zero) reads the same.
        let padded = Data([1, 2, 3]) + PhotoTest.png(300, 200)
        #expect(BotPicture.pngSize(padded.dropFirst(3))?.width == 300)
    }

    @Test func whatThisAppUploadsCanNeverReadAsAHeadCopy() {
        #expect(BotPicture.uploadSide == 256)
        #expect(BotPicture.uploadSide != BotPicture.mirrorSide && BotPicture.uploadSide != BotPicture.backfillSide)
        #expect(PhotoFramerRenderer.edge == BotPicture.uploadSide)
    }
}
