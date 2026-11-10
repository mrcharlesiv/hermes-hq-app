// [photoheads] What a profile's avatar is (docs/spec/3x-photoheads.md §4.1): a photo someone chose, the app's own
// 288 × 288 copy of a saved head (the "mirror", `S/ui-heads/mirror.ts`), desktop Hermes' 160 × 160 copy of its own face
// (the "backfill", `HB/avatar-image.ts`), nothing, or something no picture can be made from. Only a photo is drawn; a
// bot wearing anything else shows its head. Pure and `nonisolated`: call it off the main thread (it decodes).

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum BotPicture {
    enum Verdict: String, Codable, Sendable, Equatable {
        case none, mirror, backfill, photo, unreadable
    }

    /// The app's own head copy is exactly this square (`HeadRecord.mirrorSize`); desktop's face copy is the other.
    static let mirrorSide = 288
    static let backfillSide = 160
    /// The long side of the copy this phone keeps of a photo (never the original).
    static let keptSide = 256
    /// What this app uploads: a square PNG this wide (`PHOTO_EDGE`), so it can never read as a mirror or a backfill.
    static let uploadSide = 256

    struct Classified: Sendable, Equatable {
        var verdict: Verdict
        /// The first 16 hex characters of the SHA-256 of the avatar's bytes ("" when there are none).
        var fingerprint: String
        /// A photo's pixel size as drawn (orientation applied); 0 otherwise.
        var width = 0
        var height = 0
        /// A photo's kept copy: a PNG at most `keptSide` on its long side. nil for every other verdict.
        var png: Data?
    }

    /// §4.1, in order: none → mirror → backfill → photo → unreadable. The bytes decide, never the label on them.
    static func classify(found: Bool, dataURL: String?) -> Classified {
        guard found, let dataURL, !dataURL.isEmpty else { return Classified(verdict: .none, fingerprint: "") }
        guard let bytes = bytes(of: dataURL), !bytes.isEmpty else { return Classified(verdict: .unreadable, fingerprint: "") }
        let print = fingerprint(bytes)
        if let size = pngSize(bytes) {
            if size.width == mirrorSide, size.height == mirrorSide { return Classified(verdict: .mirror, fingerprint: print) }
            if size.width == backfillSide, size.height == backfillSide { return Classified(verdict: .backfill, fingerprint: print) }
        }
        guard let kept = keptCopy(bytes) else { return Classified(verdict: .unreadable, fingerprint: print) }
        return Classified(verdict: .photo, fingerprint: print, width: kept.width, height: kept.height, png: kept.png)
    }

    /// The bytes behind `data:<type>;base64,<…>` (or bare base64, which the gateway also takes). nil when not base64.
    static func bytes(of dataURL: String) -> Data? {
        var text = Substring(dataURL)
        if text.hasPrefix("data:") {
            guard let comma = text.firstIndex(of: ",") else { return nil }
            guard text[..<comma].hasSuffix(";base64") else { return nil }
            text = text[text.index(after: comma)...]
        }
        return Data(base64Encoded: String(text), options: [.ignoreUnknownCharacters])
    }

    static func fingerprint(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A PNG's width and height from its IHDR (the first chunk), nil when the bytes are not a PNG.
    static func pngSize(_ bytes: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 24, Array(bytes.prefix(8)) == signature else { return nil }
        func int(_ at: Int) -> Int {
            bytes[bytes.startIndex + at..<bytes.startIndex + at + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        return (int(16), int(20))
    }

    /// The copy this phone keeps: an ImageIO thumbnail (orientation applied, the file never decoded whole) as a PNG.
    /// nil when ImageIO can't read a complete picture from the bytes (a cut-off file, text, a type it doesn't know).
    static func keptCopy(_ bytes: Data, maxPixel: Int = keptSide) -> (png: Data, width: Int, height: Int)? {
        // ImageIO draws what it can of a file that stops half-way and calls it complete, so the file's own end mark is
        // checked first: half a picture is not shown as a bot's face.
        guard isWhole(bytes),
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), image.width >= 1, image.height >= 1,
              let flat = standardised(image) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flat, nil)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return (output as Data, flat.width, flat.height)
    }

    /// 8-bit sRGB whatever the source was (CMYK, 16-bit Display P3, indexed), so the kept file is small and draws the
    /// same everywhere. Transparency is kept.
    static func standardised(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    // MARK: - Is the file all there?

    /// False when the bytes are a PNG, JPEG, GIF, WebP or HEIC/AVIF-style file that stops before its own end (a
    /// cut-off upload or download). True for anything else: whether that is a picture at all is ImageIO's call.
    static func isWhole(_ bytes: Data) -> Bool {
        bytes.withUnsafeBytes { raw -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            func be32(_ at: Int) -> Int { Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) }
            func tag(_ at: Int, _ text: StaticString) -> Bool {
                guard at >= 0, at + text.utf8CodeUnitCount <= n else { return false }
                return text.withUTF8Buffer { t in (0..<t.count).allSatisfy { b[at + $0] == t[$0] } }
            }
            guard n >= 12 else { return n > 0 && !(b[0] == 0x89 || (b[0] == 0xFF && n > 1 && b[1] == 0xD8) || tag(0, "GIF8") || tag(0, "RIFF")) }

            if b[0] == 0x89, tag(1, "PNG\r\n") {
                // Chunks: length, type, data, checksum. Whole when the walk reaches IEND inside the bytes.
                var i = 8
                while i + 12 <= n {
                    let length = be32(i)
                    guard length >= 0, i + 12 + length <= n else { return false }
                    if tag(i + 4, "IEND") { return true }
                    i += 12 + length
                }
                return false
            }

            if b[0] == 0xFF, b[1] == 0xD8 {
                // Segments up to each scan, the scan's data, and so on until the end-of-image mark.
                var i = 2
                while i + 1 < n {
                    guard b[i] == 0xFF else { return false }
                    var marker = b[i + 1]
                    while marker == 0xFF {       // fill bytes
                        i += 1
                        guard i + 1 < n else { return false }
                        marker = b[i + 1]
                    }
                    i += 2
                    if marker == 0xD9 { return true }
                    if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
                    guard i + 1 < n else { return false }
                    let length = Int(b[i]) << 8 | Int(b[i + 1])
                    guard length >= 2, i + length <= n else { return false }
                    i += length
                    guard marker == 0xDA else { continue }
                    // Scan data runs to the next mark that is not a stuffed zero or a restart.
                    while true {
                        guard i + 1 < n else { return false }
                        if b[i] == 0xFF, b[i + 1] != 0x00, !(0xD0...0xD7).contains(b[i + 1]) { break }
                        i += 1
                    }
                }
                return false
            }

            if tag(0, "GIF87a") || tag(0, "GIF89a") {
                var i = 13
                guard n >= 13 else { return false }
                if b[10] & 0x80 != 0 { i += 3 << (Int(b[10] & 0x07) + 1) }
                func skipBlocks() -> Bool {       // length-prefixed runs ending with a zero length
                    while i < n {
                        let length = Int(b[i])
                        i += 1 + length
                        if length == 0 { return true }
                    }
                    return false
                }
                while i < n {
                    switch b[i] {
                    case 0x3B: return true
                    case 0x21:
                        i += 2
                        guard skipBlocks() else { return false }
                    case 0x2C:
                        guard i + 10 <= n else { return false }
                        let packed = b[i + 9]
                        i += 10
                        if packed & 0x80 != 0 { i += 3 << (Int(packed & 0x07) + 1) }
                        i += 1       // the code size
                        guard skipBlocks() else { return false }
                    default: return false
                    }
                }
                return false
            }

            if tag(0, "RIFF"), tag(8, "WEBP") {
                let size = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
                return n >= size + 8
            }

            if tag(4, "ftyp") {
                // Boxes: each says how long it is. Whole when none runs past the end.
                var i = 0
                while i + 8 <= n {
                    var length = be32(i)
                    if length == 0 { return true }       // "to the end of the file"
                    if length == 1 {
                        guard i + 16 <= n, be32(i + 8) == 0 else { return false }
                        length = be32(i + 12)
                    }
                    guard length >= 8, i + length <= n else { return false }
                    i += length
                }
                return i == n
            }
            return true
        }
    }
}
