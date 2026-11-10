// Makes the photoheads stream's test pictures (docs/spec/3x-photoheads.md §10.2): the files the tests pick for a bot's
// photo and the JPEGs the stand-in gateway seeds. All drawn here; no downloads, no real photos.
// Usage: swift scripts/fixtures/make-photoheads-media.swift <output dir>
//
// Every picture that has an "upright" is the same four quarters, so a screenshot shows which way up it came out and
// how it was cropped: red top-left, green top-right, blue bottom-left, yellow bottom-right, a white disc in the middle.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/fixtures/photoheads-media")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func context(_ w: Int, _ h: Int, alpha: Bool = false, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!, bits: Int = 8) -> CGContext {
    var info = (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
    if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
    return CGContext(data: nil, width: w, height: h, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info)!
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
let red = rgb(0.90, 0.16, 0.16), green = rgb(0.16, 0.70, 0.27), blue = rgb(0.16, 0.27, 0.86), yellow = rgb(0.94, 0.82, 0.16)

/// The upright picture: four quarters and a white disc. A bitmap context counts y from the bottom.
func quarters(_ c: CGContext, _ w: Int, _ h: Int) {
    let hw = CGFloat(w) / 2, hh = CGFloat(h) / 2
    for (fill, rect) in [(red, CGRect(x: 0, y: hh, width: hw, height: hh)), (green, CGRect(x: hw, y: hh, width: hw, height: hh)),
                         (blue, CGRect(x: 0, y: 0, width: hw, height: hh)), (yellow, CGRect(x: hw, y: 0, width: hw, height: hh))] {
        c.setFillColor(fill)
        c.fill(rect)
    }
    let r = CGFloat(min(w, h)) * 0.16
    c.setFillColor(rgb(1, 1, 1))
    c.fillEllipse(in: CGRect(x: hw - r, y: hh - r, width: r * 2, height: r * 2))
}

func upright(_ w: Int, _ h: Int) -> CGImage {
    let c = context(w, h)
    quarters(c, w, h)
    return c.makeImage()!
}

/// The pixels a camera would store so that EXIF `orientation` shows `image` upright. Each matrix takes a point of the
/// upright picture (x right, y up) to where it is stored: the inverse of what a viewer does for that orientation.
func stored(_ image: CGImage, orientation: Int) -> CGImage {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let turned = orientation >= 5
    let c = context(turned ? image.height : image.width, turned ? image.width : image.height)
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
    c.concatenate(matrix)
    c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return c.makeImage()!
}

func write(_ name: String, type: UTType, images: [CGImage], properties: [CFString: Any]? = nil, frame: [CFString: Any]? = nil) {
    let url = out.appending(path: name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil) else {
        print("skipped \(name): this Mac cannot write \(type.identifier)")
        return
    }
    if let properties { CGImageDestinationSetProperties(dest, properties as CFDictionary) }
    for image in images { CGImageDestinationAddImage(dest, image, frame as CFDictionary?) }
    precondition(CGImageDestinationFinalize(dest), "couldn't write \(name)")
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("wrote \(name) (\(size) bytes)")
}

// A phone portrait: shown 3024 × 4032, stored landscape with orientation 6.
write("portrait.jpg", type: .jpeg, images: [stored(upright(3024, 4032), orientation: 6)],
      frame: [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.7,
              kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
                                              kCGImagePropertyGPSLongitude: 122.009, kCGImagePropertyGPSLongitudeRef: "W"],
              kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Fixture", kCGImagePropertyTIFFModel: "Phone 1"]])

// All eight EXIF orientations of one 600 × 400 picture (the stress plan's §12.4 item 3).
for orientation in 1...8 {
    write("orient-\(orientation).jpg", type: .jpeg, images: [stored(upright(600, 400), orientation: orientation)],
          frame: [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.9])
}

write("wide.png", type: .png, images: [upright(2000, 500)])
write("tall.png", type: .png, images: [upright(100, 4000)])
write("square.heic", type: .heic, images: [upright(1600, 1600)], frame: [kCGImageDestinationLossyCompressionQuality: 0.8])
write("tiny.png", type: .png, images: [upright(16, 16)])
write("landscape.jpg", type: .jpeg, images: [upright(640, 480)], frame: [kCGImageDestinationLossyCompressionQuality: 0.85])

// Half see-through: the left half is clear, the right half the quarters' right side.
let alpha = context(800, 800, alpha: true)
quarters(alpha, 800, 800)
alpha.clear(CGRect(x: 0, y: 0, width: 400, height: 800))
write("alpha.png", type: .png, images: [alpha.makeImage()!])

// Three frames; the first is the upright quarters, the others flat colours (an animated picture gives its first frame).
let frames = [upright(240, 240)] + [red, blue].map { fill -> CGImage in
    let c = context(240, 240)
    c.setFillColor(fill)
    c.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
    return c.makeImage()!
}
write("anim.gif", type: .gif, images: frames, properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
      frame: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.3]])

// Display P3, 16 bits a channel.
let p3 = context(1200, 1200, space: CGColorSpace(name: CGColorSpace.displayP3)!, bits: 16)
quarters(p3, 1200, 1200)
write("p3.png", type: .png, images: [p3.makeImage()!])

// CMYK JPEG.
let cmykSpace = CGColorSpace(name: CGColorSpace.genericCMYK)!
let cmyk = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: cmykSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
for (components, rect) in [([0, 0.9, 0.9, 0] as [CGFloat], CGRect(x: 0, y: 300, width: 400, height: 300)), ([0.8, 0, 0.9, 0], CGRect(x: 400, y: 300, width: 400, height: 300)),
                           ([0.9, 0.7, 0, 0], CGRect(x: 0, y: 0, width: 400, height: 300)), ([0, 0.1, 0.9, 0], CGRect(x: 400, y: 0, width: 400, height: 300))] {
    cmyk.setFillColor(CGColor(colorSpace: cmykSpace, components: components + [1])!)
    cmyk.fill(rect)
}
write("cmyk.jpg", type: .jpeg, images: [cmyk.makeImage()!], frame: [kCGImageDestinationLossyCompressionQuality: 0.85])

// A big photo with enough detail to weigh about 1.9 MB as a JPEG (under the gateway's 2,000,000 bytes).
func detailed(_ w: Int, _ h: Int) -> CGImage {
    let c = context(w, h)
    quarters(c, w, h)
    // Deterministic speckle, so the file does not compress to nothing.
    var seed: UInt32 = 20261011
    func next() -> CGFloat { seed = seed &* 1_664_525 &+ 1_013_904_223; return CGFloat(seed >> 8 & 0xFFFF) / 65535 }
    for _ in 0..<52_000 {
        c.setFillColor(rgb(next(), next(), next(), 0.55))
        c.fill(CGRect(x: next() * CGFloat(w), y: next() * CGFloat(h), width: 6 + next() * 22, height: 6 + next() * 22))
    }
    return c.makeImage()!
}
let big = detailed(4000, 3000)
var quality = 0.80
var hugeData = Data()
// Walk the quality down until the file is under 1.95 MB (and stop: any size under the limit is fine).
while quality > 0.05 {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, big, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
    hugeData = data as Data
    if hugeData.count <= 1_950_000 { break }
    quality -= 0.04
}
try! hugeData.write(to: out.appending(path: "huge.jpg"))
print("wrote huge.jpg (\(hugeData.count) bytes, quality \(String(format: "%.2f", quality)))")

// A JPEG cut in half, a text file with a picture's name, and 33 MB of noise behind a JPEG header.
let whole = try! Data(contentsOf: out.appending(path: "landscape.jpg"))
try! whole.prefix(whole.count / 2).write(to: out.appending(path: "corrupt.jpg"))
print("wrote corrupt.jpg (\(whole.count / 2) bytes)")
try! Data("This is a text file. It only has a picture's name.\n".utf8).write(to: out.appending(path: "text.png"))
print("wrote text.png")
var noise = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
var block = [UInt8](repeating: 0, count: 1 << 20)
var state: UInt32 = 1
for i in block.indices { state = state &* 1_664_525 &+ 1_013_904_223; block[i] = UInt8(truncatingIfNeeded: state >> 16) }
for _ in 0..<33 { noise.append(contentsOf: block) }
try! noise.write(to: out.appending(path: "big.bin.jpg"))
print("wrote big.bin.jpg (\(noise.count) bytes)")
