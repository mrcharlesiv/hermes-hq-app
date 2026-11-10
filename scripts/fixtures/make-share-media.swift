// [share] Invented media for the Share extension's UI and stress tests (docs/spec/3x-share.md §10.4).
//
//   swift scripts/fixtures/make-share-media.swift build/fixtures/share-media
//
// Writes into that folder (made if missing; files already there are kept unless they are the wrong size):
//   clip-gps.mov   1 s, 320x240, H.264, saying where it was filmed (com.apple.quicktime.location.ISO6709)
//   clip-plain.mov the same pictures without a location
//   broken.mov     text bytes under a movie's name
//   note.txt       a short note
//   p01.jpg … p12.jpg  small photos with GPS and camera details, each a different colour
//   wide.png       a small picture with transparency
//   big.bin        101 MiB (over the 100 MiB limit)
//   exact.bin      exactly 104 857 600 bytes (the limit itself)
//   huge.jpg       8064x6048, with GPS
// and copies UITests/Fixtures/attachments/* (photo-gps.heic, photo-gps.jpg, chart.png, badge.png, report.pdf, spin.gif).
// Nothing here is real: the coordinates are a public landmark's, the camera is "FixtureCam".

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Failure: Error, CustomStringConvertible { let description: String }

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/fixtures/make-share-media.swift <folder>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
let manager = FileManager.default
try manager.createDirectory(at: folder, withIntermediateDirectories: true)
let location = "+37.3349-122.0090+010.000/"

func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

func bitmap(width: Int, height: Int, alpha: Bool = false, draw: (CGContext) -> Void) -> CGImage {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    draw(context)
    return context.makeImage()!
}

/// A flat colour with a lighter band along the top, so "which way up" is visible.
func picture(width: Int, height: Int, hue: Double) -> CGImage {
    bitmap(width: width, height: height) { context in
        let r = 0.5 + 0.5 * cos(hue * 2 * .pi), g = 0.5 + 0.5 * cos((hue + 1.0 / 3) * 2 * .pi), b = 0.5 + 0.5 * cos((hue + 2.0 / 3) * 2 * .pi)
        context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.7))
        context.fill(CGRect(x: 0, y: height - height / 6, width: width, height: height / 6))
    }
}

let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
                            kCGImagePropertyGPSLongitude: 122.009, kCGImagePropertyGPSLongitudeRef: "W"]
let camera: [CFString: Any] = [
    kCGImagePropertyGPSDictionary: gps,
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FixtureCam", kCGImagePropertyTIFFModel: "Model One"],
    kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:10 09:00:00", kCGImagePropertyExifLensModel: "Fixture Lens"],
]

func write(_ image: CGImage, as type: UTType, to url: URL, properties: [CFString: Any] = [:]) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw Failure(description: "cannot write \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw Failure(description: "cannot finish \(url.lastPathComponent)") }
}

func movie(at url: URL, location: String?) throws {
    try? manager.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA), kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
    ])
    if let location {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyLocationISO6709.rawValue as NSString
        item.identifier = .quickTimeMetadataLocationISO6709
        item.value = location as NSString
        item.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
        writer.metadata = [item]
    }
    guard writer.canAdd(input) else { throw Failure(description: "movie input") }
    writer.add(input)
    guard writer.startWriting() else { throw Failure(description: "movie start: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<30 {
        var waited = 0
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.005)
            waited += 1
            if waited > 4000 { throw Failure(description: "the encoder never became ready") }
        }
        var made: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else {
            throw Failure(description: "movie buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(40 + frame * 6 % 200), CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
            throw Failure(description: "movie append: \(String(describing: writer.error))")
        }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30))
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw Failure(description: "movie finish: \(String(describing: writer.error))") }
}

func filler(_ name: String, bytes: Int) throws {
    let url = folder.appendingPathComponent(name)
    if size(url) == bytes { return }
    manager.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let block = Data(repeating: 0x5a, count: 1024 * 1024)
    var left = bytes
    while left > 0 {
        let piece = min(left, block.count)
        try handle.write(contentsOf: block.prefix(piece))
        left -= piece
    }
}

// The app's own attachment fixtures (a real HEIC with GPS, a PDF, a GIF…).
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let shipped = root.appendingPathComponent("UITests/Fixtures/attachments", isDirectory: true)
for name in (try? manager.contentsOfDirectory(atPath: shipped.path)) ?? [] where !name.hasPrefix(".") {
    let target = folder.appendingPathComponent(name)
    if !manager.fileExists(atPath: target.path) { try manager.copyItem(at: shipped.appendingPathComponent(name), to: target) }
}

for index in 1...12 {
    let url = folder.appendingPathComponent(String(format: "p%02d.jpg", index))
    if size(url) == 0 { try write(picture(width: 640, height: 480, hue: Double(index) / 12), as: .jpeg, to: url, properties: camera) }
}
let wide = folder.appendingPathComponent("wide.png")
if size(wide) == 0 {
    let image = bitmap(width: 400, height: 200, alpha: true) { context in
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
        context.fillEllipse(in: CGRect(x: 20, y: 20, width: 360, height: 160))
    }
    try write(image, as: .png, to: wide)
}
let huge = folder.appendingPathComponent("huge.jpg")
if size(huge) == 0 { try write(picture(width: 8064, height: 6048, hue: 0.6), as: .jpeg, to: huge, properties: camera) }

try Data("A short note for the share check.\n".utf8).write(to: folder.appendingPathComponent("note.txt"))
try Data("This is not a movie. It only has a movie's name.\n".utf8).write(to: folder.appendingPathComponent("broken.mov"))
if size(folder.appendingPathComponent("clip-gps.mov")) == 0 { try movie(at: folder.appendingPathComponent("clip-gps.mov"), location: location) }
if size(folder.appendingPathComponent("clip-plain.mov")) == 0 { try movie(at: folder.appendingPathComponent("clip-plain.mov"), location: nil) }
try filler("big.bin", bytes: 101 * 1024 * 1024)
try filler("exact.bin", bytes: 100 * 1024 * 1024)

// The movie must really say where it was filmed, or the "location is removed" check proves nothing.
let clip = try Data(contentsOf: folder.appendingPathComponent("clip-gps.mov"))
guard clip.range(of: Data("+37.3349-122.0090".utf8)) != nil else { throw Failure(description: "clip-gps.mov carries no location") }
let plain = try Data(contentsOf: folder.appendingPathComponent("clip-plain.mov"))
guard plain.range(of: Data("+37.3349".utf8)) == nil else { throw Failure(description: "clip-plain.mov carries a location") }

let names = try manager.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
print("share media: \(names.count) files in \(folder.path)")
