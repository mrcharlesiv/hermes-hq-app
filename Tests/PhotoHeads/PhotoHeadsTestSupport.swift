// [photoheads] Pictures drawn in code for the photo-head tests (no downloads, no real photos).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import HermesHQNative

nonisolated enum PhotoTest {
    struct RGBA: Equatable, Sendable, CustomStringConvertible {
        var r: Int, g: Int, b: Int, a: Int
        var description: String { "(\(r), \(g), \(b), \(a))" }
        func near(_ other: RGBA, within slack: Int = 24) -> Bool {
            abs(r - other.r) <= slack && abs(g - other.g) <= slack && abs(b - other.b) <= slack
        }
    }

    static let red = RGBA(r: 230, g: 40, b: 40, a: 255)
    static let green = RGBA(r: 40, g: 180, b: 70, a: 255)
    static let blue = RGBA(r: 40, g: 70, b: 220, a: 255)
    static let yellow = RGBA(r: 240, g: 210, b: 40, a: 255)

    /// The same 96 × 96 lossless WebP the stand-in gateway seeds for the `webp` bot (`scripts/fixtures/photoheads-gateway.py`).
    static let webpBase64 = "UklGRuYAAABXRUJQVlA4TNoAAAAvX8AXAH+gEJIkZy77ex3CMXw9QNJQEwBochGGEnz0T8Gtc1UTSYq0RfQKIEcDrjCHNeJ75j/+/1lAARagMNBK0qbRXHS4c4NNEuPgMltk4YKbCACQCClABCugDcggCYjAUcGZmQjgu0YgArP9f4DfcYclov8K2rZhHA47FH7PRJXvLVDyHVKwzAJx3ZAIBhaIbC8vhGYmR4DToLE3uT80Ddn+JhfBz6JSU3s5n2W4At9LapZhy0ovsX5fLD8Hlp8zy8/t587yd+Dyd+byd/tFtfwft8Kf+Ej0Aw=="

    static func context(_ width: Int, _ height: Int, alpha: Bool = true) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
    }

    static func color(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    static func flat(_ width: Int, _ height: Int, _ fill: RGBA = blue) -> CGImage {
        let context = context(width, height)
        context.setFillColor(color(fill))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Four flat quarters as seen upright: red top-left, green top-right, blue bottom-left, yellow bottom-right.
    static func quadrants(_ width: Int, _ height: Int) -> CGImage {
        let context = context(width, height)
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        // A bitmap context counts y from the bottom: the "top" quarters are the upper half.
        for (fill, rect) in [(red, CGRect(x: 0, y: h, width: w, height: h)), (green, CGRect(x: w, y: h, width: w, height: h)),
                             (blue, CGRect(x: 0, y: 0, width: w, height: h)), (yellow, CGRect(x: w, y: 0, width: w, height: h))] {
            context.setFillColor(color(fill))
            context.fill(rect)
        }
        return context.makeImage()!
    }

    /// The left half see-through, the right half `fill`.
    static func halfClear(_ side: Int, _ fill: RGBA = green) -> CGImage {
        let context = context(side, side)
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(color(fill))
        context.fill(CGRect(x: side / 2, y: 0, width: side / 2, height: side))
        return context.makeImage()!
    }

    /// A 16-bit Display P3 picture with a horizontal ramp (so it does not compress to nothing).
    static func wideColor(_ side: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 16, bytesPerRow: 0, space: space, bitmapInfo: info)!
        for x in 0..<side {
            let t = CGFloat(x) / CGFloat(side)
            context.setFillColor(CGColor(colorSpace: space, components: [t, 1 - t, 0.5 + t / 2, 1])!)
            context.fill(CGRect(x: x, y: 0, width: 1, height: side))
        }
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func png(_ width: Int, _ height: Int, _ fill: RGBA = blue) -> Data { encode(flat(width, height, fill), type: .png) }
    static func jpeg(_ width: Int, _ height: Int, _ fill: RGBA = blue) -> Data { encode(flat(width, height, fill), type: .jpeg) }

    /// A JPEG whose stored pixels are turned so that EXIF `orientation` shows `quadrants` upright.
    static func orientedJPEG(_ width: Int, _ height: Int, orientation: Int) -> Data {
        let upright = quadrants(width, height)
        let stored = turned(upright, toStoreFor: orientation)
        return encode(stored, type: .jpeg, properties: [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.95])
    }

    /// The pixels a camera would store so that EXIF `orientation` (1…8) shows `upright` upright. Each matrix takes a point
    /// of the upright picture (x right, y up) to where it is stored: the inverse of what a viewer does for that orientation.
    static func turned(_ upright: CGImage, toStoreFor orientation: Int) -> CGImage {
        let w = CGFloat(upright.width), h = CGFloat(upright.height)
        let swapped = orientation >= 5
        let context = context(swapped ? upright.height : upright.width, swapped ? upright.width : upright.height)
        let matrix: CGAffineTransform
        switch orientation {
        case 2: matrix = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)       // mirrored left to right
        case 3: matrix = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)      // upside down
        case 4: matrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)       // mirrored top to bottom
        case 5: matrix = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)      // transposed
        case 6: matrix = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)       // the viewer turns it clockwise
        case 7: matrix = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)        // transverse
        case 8: matrix = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)       // the viewer turns it counter-clockwise
        default: matrix = .identity
        }
        context.concatenate(matrix)
        context.draw(upright, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()!
    }

    static func dataURL(_ bytes: Data, mime: String = "image/png") -> String { "data:\(mime);base64," + bytes.base64EncodedString() }

    static func decode(_ bytes: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// One pixel, x from the left and y from the **top**, as 8-bit sRGB.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGBA {
        let context = context(1, 1)
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let p = context.data!.assumingMemoryBound(to: UInt8.self)
        return RGBA(r: Int(p[0]), g: Int(p[1]), b: Int(p[2]), a: Int(p[3]))
    }

    /// PNG IHDR: width, height, bit depth, colour type (2 = RGB, 6 = RGBA).
    static func ihdr(_ png: Data) -> (width: Int, height: Int, depth: Int, colorType: Int)? {
        guard let size = BotPicture.pngSize(png), png.count > 26 else { return nil }
        return (size.width, size.height, Int(png[png.startIndex + 24]), Int(png[png.startIndex + 25]))
    }

    static func temporaryFile(_ bytes: Data, name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("photoheads-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try? bytes.write(to: url)
        return url
    }
}

// MARK: - A scripted gateway that stores avatars

extension BotPhotoTiming {
    /// Short waits for tests.
    static var fast: BotPhotoTiming {
        var t = BotPhotoTiming()
        t.fetchTimeout = .seconds(2)
        t.spacing = .milliseconds(15)
        t.revisionDelay = .milliseconds(80)
        t.followUpDelay = .milliseconds(200)
        t.retryLadder = [.milliseconds(60), .milliseconds(120), .milliseconds(180)]
        t.refreshGuard = .milliseconds(400)
        t.mirrorRetries = [.milliseconds(40), .milliseconds(80)]
        t.uploadTimeout = .seconds(2)
        return t
    }
}

/// The avatar side of a gateway: `profiles.get_asset` / `set_asset` over a dictionary, with a log and failures to order.
nonisolated final class PhotoGateway: @unchecked Sendable {
    struct State: Sendable {
        var avatars: [String: String] = [:]
        var inFlight = 0
        var maxInFlight = 0
        /// How long each `get_asset` takes.
        var delay: Duration = .zero
        /// `get_asset` failures still to hand out, per profile ("*" = any).
        var failures: [String: Int] = [:]
        /// `set_asset` failures still to hand out (an RPC code each).
        var uploadFailures: [Int] = []
        /// Answers handed out instead of the stored avatar, once each, per profile.
        var oddAnswers: [String: JSONValue] = [:]
    }

    let client: BotsFakeGatewayClient
    let state = BotsTestBox(State())

    init(account: GatewayAccount = .botsTestAccount, avatars: [String: String] = [:], connection: ConnectionState = .ready) {
        client = BotsFakeGatewayClient(account: account, state: connection)
        state.mutate { $0.avatars = avatars }
        let state = self.state
        client.on("profiles.get_asset") { params in
            let name = params["name"]?.string ?? ""
            let delay = state.mutate { s -> Duration in
                s.inFlight += 1
                s.maxInFlight = max(s.maxInFlight, s.inFlight)
                return s.delay
            }
            defer { state.mutate { $0.inFlight -= 1 } }
            if delay > .zero { await botsUncancellableSleep(delay) }
            let fail = state.mutate { s -> Bool in
                for key in [name, "*"] { if let left = s.failures[key], left > 0 { s.failures[key] = left - 1; return true } }
                return false
            }
            if fail { throw RPCError(code: 5066, message: "disk full", data: nil) }
            if let odd = state.mutate({ $0.oddAnswers.removeValue(forKey: name) }) { return odd }
            guard let data = state.value.avatars[name] else { return ["found": false] }
            return ["found": true, "mime": "image/png", "size": .number(Double(data.count)), "data": .string(data)]
        }
        client.on("profiles.set_asset") { params in
            if let code = state.mutate({ $0.uploadFailures.isEmpty ? nil : $0.uploadFailures.removeFirst() }) {
                throw RPCError(code: code, message: code == 4069 ? "asset too large (2400000 bytes; max 2MB)" : "disk full", data: nil)
            }
            let name = params["name"]?.string ?? ""
            if params["clear"]?.bool == true {
                let had = state.mutate { $0.avatars.removeValue(forKey: name) != nil }
                return ["ok": true, "asset": "avatar", "size": 0, "removed": .number(had ? 1 : 0)]
            }
            let data = params["data"]?.string ?? ""
            state.mutate { $0.avatars[name] = data }
            return ["ok": true, "asset": "avatar", "size": .number(Double(BotPicture.bytes(of: data)?.count ?? 0))]
        }
    }

    var fetches: [String] { client.calls("profiles.get_asset").map { $0.params["name"]?.string ?? "" } }
    func fetches(_ name: String) -> Int { fetches.filter { $0 == name }.count }
    var uploads: [BotsFakeGatewayClient.Call] { client.calls("profiles.set_asset") }

    func set(_ name: String, _ dataURL: String?) { state.mutate { $0.avatars[name] = dataURL } }

    /// A roster row as `profiles.list` gives it. `hasAvatar == nil` leaves the key out (a gateway without the asset store).
    static func row(_ name: String, hasAvatar: Bool? = true, bots: Int = 1, head: Int = 0, meta: [String: JSONValue] = [:]) -> JSONValue {
        var revisions: [String: JSONValue] = [:]
        if bots > 0 { revisions["hermes-bots"] = .number(Double(bots)) }
        if head > 0 { revisions["dispatch-head"] = .number(Double(head)) }
        var o: [String: JSONValue] = ["name": .string(name), "path": .string("/p/\(name)"), "is_default": .bool(name == "default"),
                                      "ui_meta_revisions": .object(revisions)]
        if let hasAvatar { o["has_avatar"] = .bool(hasAvatar) }
        if !meta.isEmpty { o["ui_meta"] = .object(meta) }
        return .object(o)
    }

    static func profile(_ name: String, hasAvatar: Bool? = true, bots: Int = 1, head: Int = 0) -> RosterProfile {
        RosterProfile(json: row(name, hasAvatar: hasAvatar, bots: bots, head: head))!
    }
}

extension PhotoTest {
    static let photoA = dataURL(png(256, 256, red))
    static let photoB = dataURL(png(256, 256, blue))
    static let mirror = dataURL(png(288, 288, green))
    static let backfill = dataURL(png(160, 160, yellow))
    static var brokenPNG: String { dataURL(png(200, 200, green).prefix(60)) }
}
